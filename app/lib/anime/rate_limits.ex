defmodule Anime.RateLimits do
  alias Anime.Repo
  @doc "Must run in the same Repo transaction as the protected write."
  def consume(scope, subject, limits) do
    Enum.each(Enum.sort(limits), fn {seconds, limit} ->
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO rate_limit_counters (scope, subject, window_seconds, window_started_at, count, inserted_at, updated_at)
        VALUES ($1,$2,$3::integer,to_timestamp(floor(extract(epoch from now())/$3::integer)*$3::integer) AT TIME ZONE 'UTC',0,now(),now())
        ON CONFLICT DO NOTHING
        """,
        [scope, subject, seconds]
      )

      %{rows: [[id, count]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          SELECT id,count FROM rate_limit_counters
          WHERE scope=$1 AND subject=$2 AND window_seconds=$3::integer
          AND window_started_at=to_timestamp(floor(extract(epoch from now())/$3::integer)*$3::integer) AT TIME ZONE 'UTC'
          FOR UPDATE
          """,
          [scope, subject, seconds]
        )

      if count >= limit do
        Anime.Log.emit(:rate_limited)
        :telemetry.execute([:anime, :rate_limit, :rejected], %{count: 1}, %{scope: scope})
        Repo.rollback(:rate_limited)
      end

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE rate_limit_counters SET count=count+1, updated_at=now() WHERE id=$1",
        [id]
      )
    end)

    :ok
  end

  def reset_login(login, ip) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM rate_limit_counters WHERE scope='login' AND subject=$1",
      [Jason.encode!([login, ip])]
    )
  end
end
