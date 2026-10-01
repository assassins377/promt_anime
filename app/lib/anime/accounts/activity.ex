defmodule Anime.Accounts.Activity do
  @moduledoc "Read-only account activity, projected without before/after values."
  import Ecto.Query
  alias Anime.{Access, Audit, Repo}

  @actions ~w(register email_confirm login login_rate_limited logout session_revoke session_revoke_others
    password_reset_request password_change locale_change preferences_change
    nick_change email_change_request email_change_confirm account_delete_request account_delete_cancel
    account_delete_final owner_create users.user.edit users.user.delete users.user.ban users.user.unban
    users.role.assign users.session.revoke)
  def actions, do: @actions

  def list(actor, params \\ %{}) do
    Access.protect(actor, "users.activity.view", "AuditLog", nil, fn _ ->
      p = normalize(params)
      q = from a in Audit, where: a.action in ^@actions
      q = if p.user_id, do: where(q, [a], a.user_id == ^p.user_id), else: q
      q = if p.actions == [], do: q, else: where(q, [a], a.action in ^p.actions)
      q = if p.result == [], do: q, else: where(q, [a], a.result in ^p.result)
      q = if p.ip == "", do: q, else: where(q, [a], a.ip == ^p.ip)

      q =
        if p.from,
          do: where(q, [a], a.occurred_at >= ^DateTime.new!(p.from, ~T[00:00:00])),
          else: q

      q =
        if p.to,
          do: where(q, [a], a.occurred_at < ^DateTime.new!(Date.add(p.to, 1), ~T[00:00:00])),
          else: q

      count = Repo.aggregate(q, :count)
      pages = max(1, ceil(count / 50))
      page = min(p.page, pages)
      field = if p.sort == "id", do: :id, else: :occurred_at
      dir = if p.dir == "asc", do: :asc, else: :desc

      rows =
        Repo.all(
          from a in q,
            order_by: [{^dir, field(a, ^field)}, {^dir, a.id}],
            limit: 50,
            offset: ^((page - 1) * 50),
            select:
              map(a, [
                :id,
                :occurred_at,
                :user_id,
                :actor_label,
                :role_code,
                :ip,
                :action,
                :result
              ])
        )

      %{rows: rows, count: count, pages: pages, page: page, params: p}
    end)
  end

  defp normalize(p) do
    %{
      user_id: id(p["user_id"]),
      actions: Enum.filter(List.wrap(p["action"]), &(&1 in @actions)),
      result: Enum.filter(List.wrap(p["result"]), &(&1 in ~w(success denied error))),
      ip: if(is_binary(p["ip"]), do: String.slice(String.trim(p["ip"]), 0, 64), else: ""),
      from: date(p["from"]),
      to: date(p["to"]),
      page: max(1, id(p["page"]) || 1),
      sort: if(p["sort"] == "id", do: "id", else: "occurred_at"),
      dir: if(p["dir"] == "asc", do: "asc", else: "desc")
    }
  end

  defp date(v) when is_binary(v) do
    case Date.from_iso8601(v) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp date(_), do: nil
  defp id(nil), do: nil
  defp id(""), do: nil
  defp id(n) when is_integer(n) and n > 0 and n < 9_223_372_036_854_775_807, do: n

  defp id(n) when is_binary(n) do
    case Integer.parse(n) do
      {n, ""} -> id(n)
      _ -> 0
    end
  end

  defp id(_), do: 0
end
