defmodule Anime.Workers.DeleteAccounts do
  use Anime.Worker, queue: :maintenance, max_attempts: 5
  import Ecto.Query
  alias Anime.{Repo, Accounts.User, Accounts.Lifecycle}

  @impl true
  def perform(_) do
    cutoff = DateTime.add(DateTime.utc_now(), -30 * 86400)
    sweep(cutoff, 0, :ok)
  end

  defp sweep(cutoff, after_id, outcome) do
    ids =
      Repo.all(
        from u in User,
          where: u.id > ^after_id and u.deletion_requested and u.deletion_requested_at <= ^cutoff,
          order_by: u.id,
          limit: 200,
          select: u.id
      )

    outcome =
      Enum.reduce(ids, outcome, fn id, result ->
        case Lifecycle.delete_due_account(id) do
          {:ok, _} -> result
          {:error, _} -> {:error, :cleanup_incomplete}
        end
      end)

    # One account needing manual intervention must not prevent cleanup of others.
    if ids == [], do: outcome, else: sweep(cutoff, List.last(ids), outcome)
  end
end
