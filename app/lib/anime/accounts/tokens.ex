defmodule Anime.Accounts.Tokens do
  import Ecto.Query
  alias Anime.{Repo, Accounts.UserToken, Accounts.User}

  @durations %{
    session: 60 * 86400,
    remember_me: 60 * 86400,
    confirm: 7 * 86400,
    reset_password: 3600,
    change_email: 7 * 86400,
    delete_cancel: 30 * 86400
  }

  def issue(user, context, meta \\ %{}) do
    now = DateTime.utc_now()

    record = %UserToken{
      user_id: user.id,
      context: context,
      sent_to:
        if(context in [:session, :remember_me],
          do: nil,
          else: Map.get(meta, :sent_to, user.email)
        ),
      ip: Map.get(meta, :ip),
      user_agent: Map.get(meta, :user_agent),
      expires_at:
        DateTime.add(
          if(context == :delete_cancel, do: user.deletion_requested_at, else: now),
          Map.fetch!(@durations, context),
          :second
        ),
      last_used_at: now
    }

    if context in [:session, :remember_me] do
      raw = :crypto.strong_rand_bytes(32)
      Repo.insert!(%{record | token: digest(raw)})
      Base.url_encode64(raw, padding: false)
    else
      # A nonce prevents a reconstructible token from depending only on guessable IDs.
      record =
        Repo.insert!(%{
          record
          | token: :crypto.strong_rand_bytes(32),
            issue_nonce: :crypto.strong_rand_bytes(32)
        })

      raw = mail_bytes(record)
      record |> Ecto.Changeset.change(token: digest(raw)) |> Repo.update!()
      %{token_id: record.id, raw: Base.url_encode64(raw, padding: false)}
    end
  end

  def mail_bytes(t) do
    secret = Application.fetch_env!(:anime, AnimeWeb.Endpoint) |> Keyword.fetch!(:secret_key_base)
    key = :crypto.mac(:hmac, :sha256, secret, "mail-token")

    payload =
      Jason.encode!([
        t.id,
        to_string(t.context),
        t.sent_to,
        DateTime.to_iso8601(t.expires_at),
        Base.encode64(t.issue_nonce)
      ])

    :crypto.mac(:hmac, :sha256, key, payload)
  end

  def digest(raw), do: :crypto.hash(:sha256, raw)

  def find(encoded, contexts) when is_binary(encoded) do
    with {:ok, raw} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(raw) == 32,
         %UserToken{} = t <-
           Repo.one(
             from t in UserToken,
               where:
                 t.token == ^digest(raw) and t.context in ^contexts and
                   t.expires_at > ^DateTime.utc_now()
           ),
         true <-
           t.context in [:session, :remember_me] || Plug.Crypto.secure_compare(raw, mail_bytes(t)) do
      t
    else
      _ -> nil
    end
  end

  def find(_, _), do: nil

  def user(encoded) do
    with %UserToken{user_id: id} = t <- find(encoded, [:session]),
         %User{} = u <- Repo.get(User, id),
         true <- User.active?(u) do
      if is_nil(t.last_used_at) || DateTime.diff(DateTime.utc_now(), t.last_used_at) >= 60 do
        Repo.update_all(from(s in UserToken, where: s.id == ^t.id),
          set: [last_used_at: DateTime.utc_now()]
        )
      end

      Repo.preload(u, :role)
    else
      _ -> nil
    end
  end

  def revoke(encoded, contexts \\ [:session, :remember_me]) do
    if t = find(encoded, contexts), do: Repo.delete(t)
    :ok
  end
end
