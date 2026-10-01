defmodule Anime.MailUniquenessTest do
  use Anime.DataCase
  alias Anime.Workers.Mail

  test "the same token is queued once regardless of locale" do
    first = insert!(%{token_id: 1001, locale: "ru"})
    duplicate = insert!(%{token_id: 1001, locale: "en"})
    assert duplicate.id == first.id
    assert duplicate.conflict?
    assert duplicate.args["locale"] == "ru"
    refute insert!(%{token_id: 1002, locale: "ru"}).id == first.id
  end

  test "security notices retain distinct events, recipients and mail kinds" do
    args = %{audit_id: 1001, user_id: 1002, kind: "password_changed", locale: "ru"}
    first = insert!(args)
    assert insert!(args).id == first.id

    for changed <- [
          %{args | audit_id: 1003},
          %{args | user_id: 1004},
          %{args | kind: "account_blocked"}
        ] do
      refute insert!(changed).id == first.id
    end
  end

  test "the sixty-second deduplication also covers completed and discarded jobs" do
    for {state, id} <-
          Enum.with_index(
            ~w(available scheduled executing retryable completed cancelled discarded),
            1000
          ) do
      args = %{token_id: id, locale: "ru"}
      first = insert!(args)
      Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id), set: [state: state])
      assert insert!(args).id == first.id
    end
  end

  test "a new task is allowed after the uniqueness window" do
    args = %{token_id: 1001, locale: "ru"}
    first = insert!(args)
    old = DateTime.add(DateTime.utc_now(), -61, :second)
    Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id), set: [inserted_at: old])
    refute insert!(args).id == first.id
  end

  defp insert!(args), do: args |> Mail.new() |> Oban.insert!()
end
