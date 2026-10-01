defmodule Anime.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :nick, :string
    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true
    field :consent, :boolean, virtual: true
    field :email_confirmed_at, :utc_datetime_usec
    field :previous_nick, :string
    field :previous_nick_until, :utc_datetime_usec
    field :nick_changed_at, :utc_datetime_usec
    field :avatar_key_320, :string
    field :avatar_key_80, :string
    field :locale, Ecto.Enum, values: [:ru, :en], default: :ru
    belongs_to :role, Anime.Access.Role
    field :status, Ecto.Enum, values: [:active, :blocked], default: :active
    field :block_reason, :string
    field :blocked_at, :utc_datetime_usec
    field :blocked_until, :utc_datetime_usec
    field :blocked_by_id, :integer
    field :deletion_requested, :boolean, default: false
    field :deletion_requested_at, :utc_datetime_usec
    field :must_change_password, :boolean, default: false
    field :show_bookmarks_public, :boolean, default: true
    field :keep_watch_history, :boolean, default: true
    field :age_confirmed_at, :utc_datetime_usec
    field :consent_accepted_at, :utc_datetime_usec
    field :consent_version, :string
    field :show_continue_watching, :boolean, default: true
    field :supporter_until, :utc_datetime_usec
    field :last_voice_over_id, :integer
    field :player_volume, :integer, default: 100

    field :player_quality, Ecto.Enum,
      values: [:auto, :"360p", :"480p", :"720p", :"1080p"],
      default: :auto

    field :subtitles_enabled, :boolean, default: false
    field :subtitle_language, :string
    field :subtitle_size, Ecto.Enum, values: [:small, :medium, :large], default: :medium
    field :autoplay_next, :boolean, default: true
    timestamps(type: :utc_datetime_usec)
  end

  @reserved ~w(admin moderator support anime watch catalog search profile u login register donate)
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :nick, :password, :password_confirmation, :consent, :locale])
    |> update_change(:email, &normalize_email/1)
    |> update_change(:nick, &trim/1)
    |> validate_required([:email, :nick, :password, :password_confirmation])
    |> validate_length(:email, max: 254)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u)
    |> validate_length(:nick, min: 3, max: 32)
    |> validate_format(:nick, ~r/^[a-zA-Z0-9_-]+$/)
    |> validate_change(:nick, fn :nick, n ->
      if String.downcase(n) in @reserved, do: [nick: "is reserved"], else: []
    end)
    |> validate_acceptance(:consent)
    |> validate_password()
    |> unique_constraint(:email)
    |> unique_constraint(:nick)
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_required([:password, :password_confirmation])
    |> validate_password()
  end

  def nick_changeset(user, attrs) do
    user
    |> cast(attrs, [:nick])
    |> update_change(:nick, &trim/1)
    |> validate_required([:nick])
    |> validate_length(:nick, min: 3, max: 32)
    |> validate_format(:nick, ~r/^[a-zA-Z0-9_-]+$/)
    |> validate_change(:nick, fn :nick, n ->
      if String.downcase(n) in @reserved, do: [nick: "is reserved"], else: []
    end)
    |> unique_constraint(:nick)
    |> unique_constraint(:previous_nick)
  end

  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_length(:email, max: 254)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u)
    |> unique_constraint(:email)
  end

  def admin_changeset(user, attrs) do
    user
    |> nick_changeset(attrs)
    |> email_changeset(attrs)
    |> cast(attrs, [:locale])
    |> validate_required([:locale])
  end

  # Ecto casts an explicitly cleared string to nil, including form recovery.
  # Preserve it so validate_required can report the error without crashing.
  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
  defp normalize_email(nil), do: nil
  defp normalize_email(value), do: value |> String.trim() |> String.downcase()

  defp validate_password(cs) do
    cs
    |> validate_length(:password, min: 12, max: 72)
    |> validate_confirmation(:password, required: true)
    |> validate_change(:password, fn :password, p ->
      cond do
        byte_size(p) > 72 ->
          [password: "must be at most 72 UTF-8 bytes"]

        not Regex.match?(~r/\p{L}/u, p) or not Regex.match?(~r/[0-9]/, p) ->
          [password: "needs a letter and a digit"]

        String.downcase(p) in [get_field(cs, :email), String.downcase(get_field(cs, :nick) || "")] ->
          [password: "must differ from your email and nickname"]

        Anime.Passwords.common?(p) ->
          [password: "is too common"]

        true ->
          []
      end
    end)
  end

  def hash_password(%Ecto.Changeset{valid?: true} = cs) do
    case get_change(cs, :password) do
      nil ->
        cs

      p ->
        cs
        |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(p))
        |> delete_change(:password)
        |> delete_change(:password_confirmation)
    end
  end

  def hash_password(cs), do: cs
  def active?(%__MODULE__{status: :active, deletion_requested: false}), do: true
  def active?(_), do: false
end
