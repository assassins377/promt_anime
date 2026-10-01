defmodule Anime.Coverage do
  @moduledoc "Line coverage gates for the implemented slice; no runtime dependency."

  @contexts ~w(accounts access settings audit rate_limits catalog media activity discussions search notifications support billing ops blog)
  @plugs ~w(AnimeWeb.Auth AnimeWeb.ClientIP AnimeWeb.Metrics AnimeWeb.MetricsPlug AnimeWeb.RequestLog AnimeWeb.RequestPipeline AnimeWeb.SecurityHeaders)
  @policy %{
    version: 1,
    overall: 80,
    context: 90,
    worker: 85,
    plug: 100,
    permissions: 100,
    contexts: @contexts,
    plugs: @plugs,
    exclusions: [
      "test/support",
      "priv/repo/migrations",
      "lib/mix/tasks",
      "seed code",
      "HEEx sigils",
      "generated line 0"
    ]
  }

  # The custom tool is loaded by mix.exs, outside the application's BEAM files.
  # Keep Mix's HTML reports as unfiltered diagnostic evidence, not as our gate.
  def start(path, options) do
    if options[:export], do: Mix.raise("Layer gates require a complete, unpartitioned test run")
    finish = Mix.Tasks.Test.Coverage.start(path, Keyword.put(options, :summary, false))

    fn ->
      finish.()
      report = collect(path)
      output = Keyword.get(options, :output, "cover")
      File.write!(Path.join(output, "coverage.json"), JSON.encode!(report))
      File.write!(Path.join(output, "coverage.txt"), render(report))
      Mix.shell().info(render(report))

      unless report.passed do
        System.at_exit(fn _ -> exit({:shutdown, 3}) end)
      end
    end
  end

  def policy_hash do
    :crypto.hash(:sha256, :erlang.term_to_binary(@policy)) |> Base.encode16(case: :lower)
  end

  def layer(module, source, behaviours \\ []) do
    root = source |> String.replace_prefix("lib/anime/", "") |> String.split(["/", "."]) |> hd()

    cond do
      module == "Anime.Access" ->
        {:permissions, 100}

      module in @plugs ||
          (Plug in behaviours &&
             !String.starts_with?(source, "lib/anime_web/controllers/") &&
             module not in ["AnimeWeb.Router", "AnimeWeb.Endpoint"]) ->
        {:plug, 100}

      Oban.Worker in behaviours || String.starts_with?(source, "lib/anime/workers/") ->
        {:worker, 85}

      String.starts_with?(source, "lib/anime/") && root in @contexts ->
        {:context, 90}

      true ->
        {:general, nil}
    end
  end

  def exclusion(source) do
    cond do
      String.starts_with?(source, "test/support/") -> "test support, not application code"
      String.starts_with?(source, "priv/repo/migrations/") -> "migration"
      String.starts_with?(source, "lib/mix/tasks/") -> "mix task"
      source in ["lib/anime/seeds.ex", "priv/repo/seeds.exs"] -> "seed implementation"
      Path.extname(source) == ".heex" -> "HEEx template"
      true -> nil
    end
  end

  # Only the literal ~H range is excluded. assign/validation/helpers in the
  # same LiveView/component remain measured. Never exclude a whole UI module.
  def template_lines(source) do
    ast = Code.string_to_quoted!(source, columns: true, token_metadata: true)

    {_, lines} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:sigil_H, meta, [{:<<>>, _, [text]}, _]} = node, acc when is_binary(text) ->
          first = Keyword.fetch!(meta, :line)
          # Uppercase H is a raw literal. Heredocs omit the opening newline
          # from the AST text; ordinary quoted sigils do not.
          opening = if byte_size(Keyword.fetch!(meta, :delimiter)) == 3, do: 1, else: 0
          last = first + opening + length(String.split(text, "\n")) - 1
          {node, Enum.reduce(first..last, acc, &MapSet.put(&2, &1))}

        node, acc ->
          {node, acc}
      end)

    lines
  end

  def counts(rows, excluded \\ MapSet.new()) do
    # OTP may return multiple probes for one line: any hit covers that line.
    lines =
      Enum.reduce(rows, %{}, fn {line, {hit, _miss}}, acc ->
        if line == 0 || MapSet.member?(excluded, line),
          do: acc,
          else: Map.update(acc, line, hit > 0, &(&1 || hit > 0))
      end)

    missed = for {line, false} <- lines, do: line

    %{
      covered: map_size(lines) - length(missed),
      total: map_size(lines),
      missed: Enum.sort(missed)
    }
  end

  def percentage(%{total: 0}), do: nil
  def percentage(%{covered: covered, total: total}), do: covered * 100 / total
  def meets?(%{total: 0}, _threshold), do: true
  def meets?(%{covered: covered, total: total}, threshold), do: covered * 100 >= total * threshold

  def regression(current, baseline, expected_revision) do
    with %{
           "version" => 1,
           "policy" => policy,
           "passed" => true,
           "revision" => revision,
           "overall" => %{"covered" => covered, "total" => total}
         } <- baseline,
         true <- policy == policy_hash(),
         true <-
           is_binary(expected_revision) &&
             Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, expected_revision),
         true <- revision == expected_revision,
         true <-
           is_integer(covered) && is_integer(total) && total > 0 && covered >= 0 &&
             covered <= total,
         true <- current.total > 0 do
      # Exact integer comparison: a drop of precisely 1pp is allowed, not 1.01.
      drop = covered * current.total * 100 - current.covered * total * 100

      if drop > total * current.total,
        do: {:error, "coverage dropped more than 1 percentage point"},
        else: :ok
    else
      _ -> {:error, "invalid baseline, policy mismatch or missing/mismatched base revision"}
    end
  end

  defp collect(path) do
    covered_modules = MapSet.new(:cover.modules())

    entries =
      for beam <- Path.wildcard(Path.join(path, "*.beam")) do
        {:ok, {module, [compile_info: compile]}} =
          :beam_lib.chunks(String.to_charlist(beam), [:compile_info])

        source = compile |> Keyword.fetch!(:source) |> to_string() |> Path.relative_to_cwd()
        name = inspect(module)
        reason = exclusion(source)

        cond do
          reason ->
            %{module: name, source: source, excluded: reason}

          !MapSet.member?(covered_modules, module) ->
            Mix.raise("Coverage missing compiled module #{name}")

          !String.starts_with?(source, "lib/") ->
            Mix.raise("Unclassified coverage source #{source}")

          true ->
            module_result(module, name, source)
        end
      end

    modules = entries |> Enum.reject(&Map.has_key?(&1, :excluded)) |> Enum.sort_by(& &1.module)
    exclusions = entries |> Enum.filter(&Map.has_key?(&1, :excluded)) |> Enum.sort_by(& &1.module)

    overall =
      Enum.reduce(modules, %{covered: 0, total: 0}, fn row, sum ->
        %{covered: sum.covered + row.covered, total: sum.total + row.total}
      end)

    failures =
      for row <- modules,
          row.threshold && !meets?(row, row.threshold),
          do: "#{row.module} < #{row.threshold}% (lines #{Enum.join(row.missed, ", ")})"

    failures =
      if overall.total > 0 && meets?(overall, 80),
        do: failures,
        else: ["Overall coverage < 80% or empty" | failures]

    {comparison, failures} = compare_baseline(overall, failures)

    %{
      version: 1,
      policy: policy_hash(),
      revision: revision(),
      overall: Map.put(overall, :percentage, percentage(overall)),
      modules: modules,
      exclusions: exclusions,
      baseline: comparison,
      failures: failures,
      passed: failures == []
    }
  end

  defp module_result(module, name, source) do
    {:ok, probes} = :cover.analyse(module, :coverage, :line)
    rows = Enum.map(probes, fn {{^module, line}, count} -> {line, count} end)
    templates = source |> File.read!() |> template_lines()
    result = counts(rows, templates)

    behaviours =
      module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    {layer, threshold} = layer(name, source, behaviours)

    Map.merge(result, %{
      module: name,
      source: source,
      layer: layer,
      threshold: threshold,
      percentage: percentage(result),
      template_lines: Enum.sort(templates)
    })
  end

  defp compare_baseline(overall, failures) do
    case System.get_env("QUEUE1_BASE_COVERAGE") do
      nil ->
        {"not checked: no default-branch report supplied", failures}

      file ->
        result =
          with {:ok, json} <- File.read(file),
               {:ok, data} <- JSON.decode(json),
               do: regression(overall, data, System.get_env("QUEUE1_BASE_REVISION"))

        case result do
          :ok ->
            {"passed", failures}

          _ ->
            {"failed",
             ["Baseline comparison failed (see file, revision, policy and 1pp limit)" | failures]}
        end
    end
  end

  defp revision do
    case System.cmd("git", ["rev-parse", "--verify", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp render(report) do
    rows =
      for row <- report.modules do
        score =
          if row.percentage,
            do: :erlang.float_to_binary(row.percentage, decimals: 2) <> "%",
            else: "n/a"

        "#{score}\t#{row.covered}/#{row.total}\t#{row.layer}\t#{row.threshold || "-"}\t#{row.module}"
      end

    Enum.join(
      [
        "Application line coverage (HEEx/seed/test-support excluded)",
        "percentage\tlines\tlayer\tminimum\tmodule" | rows
      ] ++
        [
          "Overall: #{inspect(report.overall)}",
          "Baseline: #{report.baseline}",
          "Gate: #{if report.passed, do: "PASS", else: "FAIL"}" | report.failures
        ],
      "\n"
    ) <> "\n"
  end
end
