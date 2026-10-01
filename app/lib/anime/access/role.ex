defmodule Anime.Access.Role do
  use Ecto.Schema
  import Ecto.Changeset

  schema "roles" do
    field :code, :string
    field :name, :string
    field :system, :boolean, default: false
    field :is_default, :boolean, default: false
    field :show_badge, :boolean, default: false
    field :position, :integer
    has_many :users, Anime.Accounts.User
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:code, :name, :show_badge])
    |> validate_required([:code, :name])
    |> validate_format(:code, ~r/^[a-z][a-z0-9_]*$/)
    |> validate_length(:code, min: 2, max: 64)
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:code)
  end
end
