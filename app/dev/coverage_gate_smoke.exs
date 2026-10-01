# Real child Mix projects: prove the coverage gate changes the process exit code.
# Uses only fresh temporary directories; no Anime/Repo or external services.
Code.require_file("coverage.exs", __DIR__)
tool = Path.expand("coverage.exs", __DIR__)
{root, 0} = System.cmd("mktemp", ["-d", "/tmp/anime-coverage-gate.XXXXXXXX"])
root = String.trim(root)

cases = [
  {"overall", "Probe", "lib/probe.ex", false, 3},
  {"context", "Anime.Accounts", "lib/anime/accounts.ex", true, 3},
  {"worker", "Anime.Workers.Mail", "lib/anime/workers/mail.ex", true, 3},
  {"plug", "AnimeWeb.Auth", "lib/anime_web/auth.ex", true, 3},
  {"permissions", "Anime.Access", "lib/anime/access.ex", true, 3},
  {"general-pass", "Probe", "lib/probe.ex", true, 0}
]

for {label, name, source, background?, expected} <- cases do
  dir = Path.join(root, label)
  File.mkdir_p!(Path.join(dir, Path.dirname(source)))
  File.mkdir_p!(Path.join(dir, "test"))

  File.write!(Path.join(dir, "mix.exs"), """
  Code.require_file(#{inspect(tool)})
  defmodule CoverageProbe.MixProject do
    use Mix.Project
    def project, do: [app: :coverage_probe, version: "0.0.0", test_coverage: [tool: Anime.Coverage]]
  end
  """)

  File.write!(Path.join(dir, source), """
  defmodule #{name} do
    def hit, do: Integer.to_string(1)
    def miss, do: Integer.to_string(2)
  end
  """)

  background =
    if background?,
      do: Enum.map_join(1..30, "\n", &"def hit(#{&1}), do: Integer.to_string(#{&1})"),
      else: ""

  File.write!(
    Path.join(dir, "lib/background.ex"),
    "defmodule Background do\n#{background}\nend\n"
  )

  File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start()\n")

  File.write!(Path.join(dir, "test/probe_test.exs"), """
  defmodule ProbeTest do
    use ExUnit.Case
    test "cover the chosen lines" do
      assert #{name}.hit() == "1"
      #{if background?, do: "for i <- 1..30, do: assert(Background.hit(i) == Integer.to_string(i))", else: ""}
    end
  end
  """)

  {output, status} =
    System.cmd(System.find_executable("mix"), ["test", "--cover"],
      cd: dir,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "test"},
        {"ELIXIR_ERL_OPTIONS", "+S 2:2"},
        {"QUEUE1_BASE_COVERAGE", nil},
        {"QUEUE1_BASE_REVISION", nil},
        {"MIX_BUILD_PATH", nil},
        {"MIX_DEPS_PATH", nil}
      ]
    )

  File.write!(Path.join(dir, "run.log"), output)
  report = dir |> Path.join("cover/coverage.json") |> File.read!() |> JSON.decode!()

  unless status == expected && report["passed"] == (expected == 0),
    do: raise("Coverage gate #{label}: expected #{expected}, received #{status}; evidence #{dir}")

  if background? && report["overall"]["percentage"] < 90,
    do: raise("Coverage gate fixture does not isolate per-module thresholds")

  IO.puts("PASS: #{label}, exit #{status}")
end

IO.puts("Coverage gate process checks: 6 passed; evidence #{root}")
