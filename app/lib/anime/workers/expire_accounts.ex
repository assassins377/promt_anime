defmodule Anime.Workers.ExpireAccounts do
  use Anime.Worker, queue: :maintenance, max_attempts: 3
  import Ecto.Query
  alias Anime.{Repo, Accounts.User, Accounts.UserToken}
  @impl true
  def perform(_job) do
    now = DateTime.utc_now()
    Repo.delete_all(from t in UserToken, where: t.expires_at < ^now)

    Repo.update_all(from(u in User, where: u.previous_nick_until < ^now),
      set: [previous_nick: nil, previous_nick_until: nil, updated_at: now]
    )

    :ok
  end
end
