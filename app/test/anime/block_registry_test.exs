defmodule Anime.BlockRegistryTest do
  use Anime.DataCase
  alias Anime.Audit
  alias Anime.Accounts.{Administration, Lifecycle, User}
  alias Anime.Access.{Permission, RolePermission}

  test "registry enforces blocked scope, operator and term independently of hostile filters" do
    owner = role_user("owner")
    target = user()
    assert {:ok, _} = Administration.ban(owner, target.id, %{"reason" => "spam", "days" => "2"})

    {:ok, listing} =
      Administration.blocked(owner, %{
        "status" => ["active"],
        "role" => owner.role_id,
        "blocked_by" => to_string(owner.id),
        "term" => "temporary"
      })

    assert Enum.map(listing.rows, & &1.id) == [target.id]
    assert listing.operators == [%{id: owner.id, nick: owner.nick}]
    row = hd(listing.rows)
    assert row.blocked_by_id == owner.id && row.blocked_by_nick == owner.nick
    refute Map.has_key?(row, :hashed_password)
    {:ok, empty} = Administration.blocked(owner, %{"term" => "permanent"})
    assert empty.rows == []
    {:ok, empty} = Administration.blocked(owner, %{"blocked_by" => to_string(target.id)})
    assert empty.rows == []
  end

  test "UTC date range uses block time, including the whole last day, not registration" do
    owner = role_user("owner")
    target = user()
    {:ok, _} = Administration.ban(owner, target.id, %{"reason" => "spam", "days" => "2"})

    for at <- [~U[2025-03-02 00:00:00.000000Z], ~U[2025-03-02 23:59:59.999999Z]] do
      Repo.update!(Ecto.Changeset.change(Repo.get!(User, target.id), blocked_at: at))

      {:ok, listing} =
        Administration.blocked(owner, %{"from" => "2025-03-02", "to" => "2025-03-02"})

      assert Enum.map(listing.rows, & &1.id) == [target.id]
    end

    {:ok, regular} = Administration.list(owner, %{"from" => "2025-03-02", "to" => "2025-03-02"})
    assert regular.rows == []

    for at <- [~U[2025-03-01 23:59:59.999999Z], ~U[2025-03-03 00:00:00.000000Z]] do
      Repo.update!(Ecto.Changeset.change(Repo.get!(User, target.id), blocked_at: at))

      {:ok, listing} =
        Administration.blocked(owner, %{"from" => "2025-03-02", "to" => "2025-03-02"})

      assert listing.rows == []
    end

    {:ok, listing} =
      Administration.blocked(owner, %{
        "from" => "invalid",
        "blocked_by" => ["bad"],
        "sort" => "injection",
        "page" => "-8"
      })

    assert listing.count == 1 && listing.page == 1 && listing.params.sort == "blocked_at"
  end

  test "registry paginates with a stable ID tie-break and never includes unblocked accounts" do
    owner = role_user("owner")
    now = DateTime.utc_now()

    base = %{
      hashed_password: owner.hashed_password,
      role_id: owner.role_id,
      consent_accepted_at: now,
      consent_version: "test",
      inserted_at: now,
      updated_at: now,
      status: :blocked,
      blocked_at: now,
      blocked_by_id: owner.id,
      block_reason: "test"
    }

    rows =
      for n <- 1..51,
          do:
            Map.merge(base, %{
              nick: "blocked#{owner.id}-#{n}",
              email: "blocked#{owner.id}-#{n}@example.test"
            })

    {51, _} = Repo.insert_all(User, rows)
    {:ok, first} = Administration.blocked(owner)
    {:ok, second} = Administration.blocked(owner, %{"page" => "999999"})
    assert length(first.rows) == 50 && length(second.rows) == 1
    assert second.page == 2 && second.pages == 2
    ids = Enum.map(first.rows ++ second.rows, & &1.id)
    assert ids == Enum.sort(ids, :desc) && length(Enum.uniq(ids)) == 51
    refute owner.id in ids
  end

  test "history is target-scoped, paginated and projects only block details" do
    owner = role_user("owner")
    target = user()
    now = DateTime.utc_now()

    entries =
      for n <- 1..51 do
        a =
          Audit.record(
            owner,
            if(rem(n, 2) == 0, do: "users.user.unban", else: "users.user.ban"),
            "User",
            target.id,
            :success,
            %{
              new_value: %{
                block_reason: "reason #{n}",
                blocked_until: nil,
                password: "never-project-this",
                email: "private@example.test"
              }
            }
          )

        Repo.update!(Ecto.Changeset.change(a, occurred_at: now))
      end

    Audit.record(owner, "users.user.edit", "User", target.id, :success)
    Audit.record(owner, "users.user.ban", "User", owner.id, :success)
    Audit.record(owner, "users.user.ban", "Post", target.id, :success)
    {:ok, first} = Administration.block_history(owner, target.id, %{"object_id" => owner.id})
    {:ok, last} = Administration.block_history(owner, target.id, %{"page" => "99"})

    assert first.count == 51 && length(first.rows) == 50 && last.page == 2 &&
             length(last.rows) == 1

    assert Enum.map(first.rows ++ last.rows, & &1.id) == Enum.map(Enum.reverse(entries), & &1.id)
    row = hd(first.rows)
    assert row.has_deadline && is_nil(row.blocked_until)
    refute Map.has_key?(row, :old_value) || Map.has_key?(row, :new_value)
    refute inspect(first) =~ "never-project-this"
    refute inspect(first) =~ "private@example.test"
    assert {:error, :not_found} = Administration.block_history(owner, "invalid")
  end

  test "history survives operator rename and includes automatic expiry, not a current block" do
    owner = role_user("owner")
    target = user()
    {:ok, _} = Administration.ban(owner, target.id, %{"reason" => "spam", "days" => "1"})
    Repo.update!(Ecto.Changeset.change(owner, nick: "renamed_operator"))

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(User, target.id),
        blocked_until: DateTime.add(DateTime.utc_now(), -1)
      )
    )

    {:ok, _} = Administration.unblock_expired(target.id)
    {:ok, registry} = Administration.blocked(owner)
    assert registry.count == 0
    {:ok, history} = Administration.block_history(owner, target.id)
    assert history.count == 2
    assert hd(history.rows).actor_label == "users_unblock_expired"
    assert List.last(history.rows).actor_label == owner.nick
    assert Enum.all?(history.rows, &(&1.block_reason == "спам"))
  end

  test "deleted operator leaves a readable anonymous history and a filterable registry row" do
    owner = role_user("owner")
    moderator = role_user("comment_moderator")
    target = user()

    {:ok, _} =
      Administration.ban(moderator, target.id, %{"reason" => "spam", "permanent" => "true"})

    {:ok, _} = Administration.request_deletion(owner, moderator.id, moderator.nick)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(User, moderator.id),
        deletion_requested_at: DateTime.add(DateTime.utc_now(), -31 * 86400)
      )
    )

    assert {:ok, _} = Lifecycle.delete_due_account(moderator.id)
    {:ok, registry} = Administration.blocked(owner, %{"blocked_by" => "missing"})
    assert Enum.map(registry.rows, & &1.id) == [target.id]
    assert registry.operators == []
    assert is_nil(hd(registry.rows).blocked_by_nick)
    {:ok, history} = Administration.block_history(owner, target.id)
    assert hd(history.rows).actor_label =~ ~r/^deleted-[0-9a-f]{8}$/
    refute inspect(history) =~ moderator.email
  end

  test "both reads independently require fresh user-view permission" do
    ordinary = user()
    admin = role_user("admin")
    assert {:error, :forbidden} = Administration.blocked(ordinary)
    assert {:error, :forbidden} = Administration.block_history(ordinary, ordinary.id)
    p = Repo.get_by!(Permission, code: "users.user.view")

    Repo.delete_all(
      from rp in RolePermission, where: rp.role_id == ^admin.role_id and rp.permission_id == ^p.id
    )

    assert {:error, :forbidden} = Administration.blocked(admin)
    assert {:error, :forbidden} = Administration.block_history(admin, ordinary.id)
  end
end
