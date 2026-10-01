# Explicit local-only fixtures, never part of normal setup or production seeds.
import Ecto.Query
alias Anime.{Repo, Accounts, Audit, Access, Settings}
alias Anime.Accounts.{User, Lifecycle}
alias Anime.Access.Role

unless Mix.env() == :dev && System.get_env("APP_ENV") == "dev" do
  raise "Demo accounts are allowed only in local development"
end

%{rows: [[database, address, port]]} =
  Ecto.Adapters.SQL.query!(
    Repo,
    "SELECT current_database(), host(inet_server_addr()), inet_server_port()",
    []
  )

unless {database, address, port} == {"anime_dev", "127.0.0.1", 59432} do
  raise "Refusing to create demo accounts outside the isolated local anime_dev database"
end

unless Application.fetch_env!(:anime, Anime.Mailer)[:adapter] == Swoosh.Adapters.Local do
  raise "Demo accounts require the local-only mail adapter"
end

accounts = [
  {"owner", "demo_owner"},
  {"admin", "demo_admin"},
  {"comment_moderator", "demo_moderator"},
  {"content_editor", "demo_editor"},
  {"user", "demo_user"}
]

{:ok, created} =
  Repo.transaction(fn ->
    Lifecycle.owner_lock!()

    Enum.map(accounts, fn {code, nick} ->
      email = nick <> "@anime.test"
      Accounts.nick_lock(nick)

      cond do
        Accounts.nick_taken?(nick) || Repo.exists?(from u in User, where: u.email == ^email) ->
          %{login: nick, role: code, status: "skipped_existing"}

        code == "owner" &&
            Repo.exists?(
              from u in User,
                join: r in Role,
                on: r.id == u.role_id,
                where: r.code == "owner" and u.status == :active and not u.deletion_requested
            ) ->
          %{login: nick, role: code, status: "skipped_existing_owner"}

        true ->
          role = Repo.get_by!(Role, code: code)
          password = "Demo9-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
          now = DateTime.utc_now()

          user =
            %User{}
            |> User.registration_changeset(%{
              email: email,
              nick: nick,
              password: password,
              password_confirmation: password,
              consent: true,
              locale: "ru"
            })
            |> User.hash_password()
            |> Ecto.Changeset.change(
              role_id: role.id,
              email_confirmed_at: now,
              consent_accepted_at: now,
              consent_version: Settings.get("legal_version"),
              must_change_password: code == "owner"
            )
            |> Repo.insert!()

          Audit.record(nil, "demo_account_create", "User", user.id, :success, %{
            actor_label: "local_demo_seed",
            new_value: %{role: code}
          })

          %{
            login: nick,
            email: email,
            role: code,
            password: password,
            status: "created",
            password_change_required: user.must_change_password
          }
      end
    end)
  end)

for account <- created do
  result =
    if account.status == "created" do
      case Accounts.authenticate(account.login, account.password, %{
             ip: "127.0.0.1",
             user_agent: "Local demo verification"
           }) do
        {:ok, user} ->
          user = Repo.preload(user, :role)

          Map.merge(account, %{
            login_verified: user.role.code == account.role,
            permissions: length(Access.permissions(user))
          })

        _ ->
          Map.put(account, :login_verified, false)
      end
    else
      account
    end

  # Credentials are intentionally shown once to the local operator, never saved in source.
  IO.puts("DEMO_ACCOUNT " <> Jason.encode!(result))
end
