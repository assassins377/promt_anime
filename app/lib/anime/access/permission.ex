defmodule Anime.Access.Permission do
  use Ecto.Schema

  schema "permissions" do
    field :code, :string
    field :name, :string

    field :group, Ecto.Enum,
      values:
        ~w(admin users roles moderation content video blog announcements feedback billing audit settings system)a

    timestamps(type: :utc_datetime_usec)
  end
end
