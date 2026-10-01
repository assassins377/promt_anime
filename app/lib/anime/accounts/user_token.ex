defmodule Anime.Accounts.UserToken do
  use Ecto.Schema

  schema "users_tokens" do
    belongs_to :user, Anime.Accounts.User
    field :token, :binary, redact: true
    field :issue_nonce, :binary, redact: true

    field :context, Ecto.Enum,
      values: [:session, :remember_me, :confirm, :reset_password, :change_email, :delete_cancel]

    field :sent_to, :string
    field :ip, :string
    field :user_agent, :string
    field :last_used_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
