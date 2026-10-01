defmodule Anime.Settings.Setting do
  use Ecto.Schema

  schema "settings" do
    field :key, :string
    field :value, :string
    field :value_type, Ecto.Enum, values: [:string, :integer, :boolean, :json]

    field :group, Ecto.Enum,
      values: [:main, :seo, :email, :registration, :notifications, :security]

    timestamps(type: :utc_datetime_usec)
  end
end
