defmodule Anime.CoveragePolicyTest do
  use ExUnit.Case, async: true
  alias Anime.Coverage

  test "critical modules cannot be hidden by a high overall score" do
    assert Coverage.layer("Anime.Access", "lib/anime/access.ex") == {:permissions, 100}

    assert Coverage.layer("Anime.Accounts.Lifecycle", "lib/anime/accounts/lifecycle.ex") ==
             {:context, 90}

    assert Coverage.layer("Anime.Settings", "lib/anime/settings.ex") == {:context, 90}
    assert Coverage.layer("Anime.Workers.Mail", "lib/anime/workers/mail.ex") == {:worker, 85}
    assert Coverage.layer("NewWorker", "lib/other.ex", [Oban.Worker]) == {:worker, 85}
    assert Coverage.layer("AnimeWeb.Auth", "lib/anime_web/auth.ex") == {:plug, 100}

    assert Coverage.layer("AnimeWeb.ProfileLive", "lib/anime_web/live/profile_live.ex") ==
             {:general, nil}

    refute Coverage.meets?(%{covered: 999, total: 1000}, 100)
    refute Coverage.meets?(%{covered: 8999, total: 10000}, 90)
    assert Coverage.meets?(%{covered: 85, total: 100}, 85)
  end

  test "seed and test scaffolding are excluded, not domain logic or UI modules" do
    for path <- [
          "test/support/fixtures.ex",
          "priv/repo/migrations/one.exs",
          "lib/anime/seeds.ex",
          "priv/repo/seeds.exs",
          "lib/mix/tasks/check.ex"
        ] do
      assert Coverage.exclusion(path)
    end

    for path <- [
          "lib/anime/accounts.ex",
          "lib/anime_web/live/profile_live.ex",
          "lib/anime_web/components/layouts.ex"
        ] do
      refute Coverage.exclusion(path)
    end
  end

  test "HEEx exclusion uses syntax, retains surrounding helpers and ignores fake sigils in strings" do
    code = ~S'''
    def render(assigns) do
      assigns = assign(assigns, :label, label())
      ~H"""
      <p>{@label}</p>
      """
    end
    def label, do: "~H\"not a template\""
    '''

    assert Coverage.template_lines(code) == MapSet.new([3, 4, 5])
    assert Coverage.template_lines("def render(assigns), do: ~H\"<p>Hi</p>\"") == MapSet.new([1])
    assert Coverage.template_lines("def other, do: 1") == MapSet.new()
    assert_raise TokenMissingError, fn -> Coverage.template_lines("def broken(") end
  end

  test "each executable line counts once and zero line is never code" do
    result =
      Coverage.counts(
        [{0, {0, 1}}, {2, {0, 1}}, {2, {1, 0}}, {3, {0, 1}}, {4, {0, 1}}],
        MapSet.new([4])
      )

    assert result == %{covered: 1, total: 2, missed: [3]}
    assert Coverage.percentage(result) == 50.0
    assert Coverage.percentage(Coverage.counts([])) == nil
    assert Coverage.meets?(Coverage.counts([]), 100)
  end

  test "drop limit is exact, not rounded to a passing displayed percentage" do
    base = baseline(9500, 10000)
    assert :ok = Coverage.regression(%{covered: 9400, total: 10000}, base, revision())
    assert {:error, _} = Coverage.regression(%{covered: 9399, total: 10000}, base, revision())
    assert :ok = Coverage.regression(%{covered: 99, total: 100}, base, revision())
  end

  test "untrusted stale incomplete or mismatched baselines fail closed" do
    base = baseline(95, 100)

    for invalid <- [
          nil,
          %{},
          %{base | "policy" => "old"},
          %{base | "passed" => false},
          %{base | "revision" => String.duplicate("b", 40)},
          %{base | "overall" => %{"covered" => 1, "total" => 0}},
          %{base | "overall" => %{"covered" => 101, "total" => 100}}
        ] do
      assert {:error, _} = Coverage.regression(%{covered: 95, total: 100}, invalid, revision())
    end

    assert {:error, _} = Coverage.regression(%{covered: 95, total: 100}, base, nil)
    assert {:error, _} = Coverage.regression(%{covered: 0, total: 0}, base, revision())
  end

  defp revision, do: String.duplicate("a", 40)

  defp baseline(covered, total),
    do: %{
      "version" => 1,
      "policy" => Coverage.policy_hash(),
      "passed" => true,
      "revision" => revision(),
      "overall" => %{"covered" => covered, "total" => total}
    }
end
