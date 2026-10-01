defmodule Anime.Access.RolePermission do
  use Ecto.Schema

  schema "role_permissions" do
    belongs_to :role, Anime.Access.Role
    belongs_to :permission, Anime.Access.Permission
    timestamps(type: :utc_datetime_usec)
  end
end
