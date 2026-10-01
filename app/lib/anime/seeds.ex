defmodule Anime.Seeds do
  import Ecto.Query
  alias Anime.{Repo, Audit, Accounts.User, Access.Catalog}
  alias Anime.Access.{Role, Permission, RolePermission}
  alias Anime.Settings.Setting

  def defaults do
    result =
      Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(7317, 1)", [])

        now = DateTime.utc_now()

        added_permissions =
          for {code, name} <- Catalog.permissions(), reduce: [] do
            added ->
              {:ok, group} =
                Ecto.Enum.cast_value(Permission, :group, code |> String.split(".") |> hd())

              {count, _} =
                Repo.insert_all(
                  Permission,
                  [%{code: code, name: name, group: group, inserted_at: now, updated_at: now}],
                  on_conflict: :nothing,
                  conflict_target: :code
                )

              if count == 1, do: [code | added], else: added
          end

        for {code, n} <- Enum.with_index(~w(user comment_moderator content_editor admin owner), 1) do
          {created, _} =
            Repo.insert_all(
              Role,
              [
                %{
                  code: code,
                  name: code,
                  system: true,
                  position: n,
                  is_default: code == "user",
                  show_badge: code in ~w(owner admin comment_moderator),
                  inserted_at: now,
                  updated_at: now
                }
              ],
              on_conflict: :nothing,
              conflict_target: :code
            )

          role = Repo.get_by!(Role, code: code)

          grants =
            if created == 1,
              do: Catalog.role_codes(code),
              else: Enum.filter(Catalog.role_codes(code), &(&1 in added_permissions))

          for p <- Repo.all(from p in Permission, where: p.code in ^grants) do
            Repo.insert!(%RolePermission{role_id: role.id, permission_id: p.id},
              on_conflict: :nothing,
              conflict_target: [:role_id, :permission_id]
            )
          end
        end

        for {key, value, type, group} <- settings() do
          Repo.insert!(%Setting{key: key, value: value, value_type: type, group: group},
            on_conflict: :nothing,
            conflict_target: :key
          )
        end
      end)

    if match?({:ok, _}, result), do: Anime.Cache.invalidate_permissions()
    result
  end

  def owner! do
    email = System.fetch_env!("ADMIN_EMAIL")
    nick = System.fetch_env!("ADMIN_NICK")
    password = System.fetch_env!("ADMIN_PASSWORD")
    {:ok, _} = defaults()

    Repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(7317, 1)", [])
      role = Repo.get_by!(Role, code: "owner")

      if Repo.exists?(
           from u in User,
             where: u.role_id == ^role.id and u.status == :active and not u.deletion_requested
         ) do
        :already_exists
      else
        cs =
          User.registration_changeset(%User{}, %{
            email: email,
            nick: nick,
            password: password,
            password_confirmation: password,
            consent: true
          })

        cs =
          cs
          |> User.hash_password()
          |> Ecto.Changeset.change(
            role_id: role.id,
            email_confirmed_at: DateTime.utc_now(),
            consent_accepted_at: DateTime.utc_now(),
            consent_version: Anime.Settings.get("legal_version"),
            must_change_password: true
          )

        u = Repo.insert!(cs)
        Audit.record(nil, "owner_create", "User", u.id, :success, %{actor_label: "seed"})
        :created
      end
    end)
  end

  defp settings do
    [
      {"site_name", "Anime", :string, :main},
      {"legal_version", "2026-01-01", :string, :main},
      {"home_categories_count", "5", :integer, :main},
      {"home_category_items", "10", :integer, :main},
      {"catalog_per_page", "30", :integer, :main},
      {"catalog_default_sort", "popularity", :string, :main},
      {"donate_monthly_goal_cents", "0", :integer, :main},
      {"video_enabled", "true", :boolean, :main},
      {"video_guest_enabled", "true", :boolean, :main},
      {"video_source_retention_days", "30", :integer, :main},
      {"cron_disabled_workers", "[]", :json, :main},
      {"blog_per_page", "12", :integer, :main},
      {"home_blog_items", "3", :integer, :main},
      {"terms_ru", "# Условия использования\n\nТекст будет опубликован до запуска.", :string,
       :main},
      {"privacy_ru", "# Конфиденциальность\n\nТекст будет опубликован до запуска.", :string,
       :main},
      {"terms_en", "# Terms of use\n\nThe policy will be published before launch.", :string,
       :main},
      {"privacy_en", "# Privacy\n\nThe policy will be published before launch.", :string, :main},
      {"registration_enabled", "true", :boolean, :registration},
      {"registration_default_role", "user", :string, :registration},
      {"security_login_attempts", "5", :integer, :security},
      {"security_login_block_minutes", "15", :integer, :security},
      {"email_from_name", "Anime", :string, :email},
      {"email_from_address", "no-reply@" <> (System.get_env("PHX_HOST") || "localhost"), :string,
       :email},
      {"notifications_default_email_enabled", "true", :boolean, :notifications},
      {"notifications_default_bell_enabled", "true", :boolean, :notifications}
    ]
  end
end
