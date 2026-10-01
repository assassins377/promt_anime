defmodule Anime.Access do
  import Ecto.Query
  alias Anime.{Repo, Audit}
  alias Anime.Accounts.User
  alias Anime.Access.{Role, Permission, RolePermission, Catalog}

  @doc "Presentation-only grants; never authorize an operation with this cached list."
  def permissions(nil), do: []

  def permissions(%User{id: id}) do
    case Repo.get(User, id) |> Repo.preload(:role) do
      %User{} = u ->
        if User.active?(u) do
          Anime.Cache.role_permissions(u.role_id, fn -> codes_for_role(u.role) end)
          |> Enum.sort()
        else
          []
        end

      _ ->
        []
    end
  end

  @doc "Uncached database grants for authorization and transactional comparisons."
  def codes_for_role(%Role{code: "owner"}), do: Catalog.codes()

  def codes_for_role(%Role{id: id}) do
    Repo.all(
      from p in Permission,
        join: rp in RolePermission,
        on: rp.permission_id == p.id,
        where: rp.role_id == ^id,
        select: p.code
    )
  end

  def allowed?(nil, _), do: false

  def allowed?(%User{id: id}, code) do
    case Repo.get(User, id) |> Repo.preload(:role) do
      %User{role: role} = u ->
        User.active?(u) && (role.code == "owner" || code in codes_for_role(role))

      _ ->
        false
    end
  end

  # Every protected transaction locks the actor before their role; UI state is never trusted.
  def protect(actor, code, type, id, fun) do
    result =
      Repo.transaction(fn ->
        u = actor && Repo.one(from u in User, where: u.id == ^actor.id, lock: "FOR SHARE")
        unless User.active?(u), do: Repo.rollback(:forbidden)
        role = Repo.one!(from r in Role, where: r.id == ^u.role_id, lock: "FOR SHARE")
        u = %{u | role: role}
        unless role.code == "owner" || code in codes_for_role(role), do: Repo.rollback(:forbidden)
        fun.(u)
      end)

    if result == {:error, :forbidden} do
      Repo.transaction(fn ->
        # The failed operation released its lock. Re-read and lock for the
        # audit insert as deletion may have committed in the meantime. A stale
        # struct must not restore erased identity data or violate the audit FK.
        current =
          if actor do
            Repo.one(from u in User, where: u.id == ^actor.id, lock: "FOR SHARE")
            |> Repo.preload(:role)
          end

        Audit.record(current, code, type, id, :denied)
      end)
    end

    result
  end

  defdelegate update_matrix(actor, role_id, requested), to: Anime.Access.Roles
end
