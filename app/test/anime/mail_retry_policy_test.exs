defmodule Anime.MailRetryPolicyTest do
  use ExUnit.Case, async: true
  alias Anime.Workers.Mail

  test "mail uses its specified finite timeout and five attempts" do
    assert Mail.timeout(%Oban.Job{}) == 30_000
    job = Mail.new(%{token_id: 123, locale: "ru"})
    assert Ecto.Changeset.get_field(job, :max_attempts) == 5
    assert Ecto.Changeset.get_field(job, :queue) == "mailers"
  end

  test "backoff is deterministic seconds without the default jitter" do
    assert for(attempt <- 1..5, do: Mail.backoff(%Oban.Job{attempt: attempt})) ==
             [60, 300, 900, 3600, 7200]

    assert Mail.backoff(%Oban.Job{attempt: 0}) == 60
    assert Mail.backoff(%Oban.Job{attempt: 6}) == 7200
  end
end
