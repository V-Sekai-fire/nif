defmodule Taskweft.DifferentialTest do
  use ExUnit.Case, async: false

  alias Taskweft.Differential.{Build, Corpus, Run}

  @moduletag :differential
  @moduletag timeout: 600_000

  @base_budget_ms 5_000
  @variant_budget_ms 1_000
  @corpus_digest "09dda9928eedeb1bb07ab773cd21e2b5185da428cc789aab0f540212bf5eb5a0"
  @golden_disagreements [
    "golden/entity_capabilities__entity_caps_goal",
    "golden/service_bringup__chi176_local_infra_bringup"
  ]

  setup_all do
    work = Path.join(Mix.Project.build_path(), "differential")
    {build_us, builds} = :timer.tc(fn -> Build.build(Build.variants()) end)
    cases = Corpus.all(Path.join(work, "corpus"))
    traces = Path.join(work, "traces")
    File.rm_rf!(traces)
    base = Run.run(builds.base, cases, @base_budget_ms, traces: traces, parallel: false)

    IO.puts(
      "\ndifferential: #{length(cases)} cases, #{map_size(builds)} builds in #{div(build_us, 1000)} ms, traces in #{traces}"
    )

    %{builds: builds, cases: cases, base: base}
  end

  test "the corpus is enumerated and pinned", %{cases: cases} do
    families = cases |> Enum.frequencies_by(& &1.family) |> Enum.sort()
    IO.puts("corpus: #{inspect(families)}, math/random domains #{Enum.count(cases, & &1.random)}")
    IO.puts("goldens not runnable here: #{length(Corpus.unreachable_goldens())}")

    for {name, why} <- Corpus.unreachable_goldens(),
        do: IO.puts("  MISSING golden #{name}: #{why}")

    assert Corpus.digest(cases) == @corpus_digest
  end

  test "base re-run agrees on status, plan bytes and oracle-request trace", ctx do
    assert Enum.reject(ctx.cases, &(ctx.base[&1.id].status in ["ok", "no_plan"])) == []
    rerun = Run.run(ctx.builds.base, Enum.reverse(ctx.cases), @base_budget_ms)
    cmp = Run.compare(ctx.cases, ctx.base, rerun)
    us = Enum.map(Map.values(ctx.base), & &1.us)

    {events, bytes} =
      Enum.reduce(Map.values(ctx.base), {0, 0}, fn r, {e, b} ->
        {e + elem(r.trace, 1), b + elem(r.trace, 2)}
      end)

    solved = Enum.count(Map.values(ctx.base), &(&1.status == "ok"))
    IO.puts(Run.summary("base vs re-run", cmp))

    IO.puts(
      "base: solved #{solved}/#{length(ctx.cases)}, plan µs median #{Run.percentile(us, 50)} p90 #{Run.percentile(us, 90)} max #{Enum.max(us)}, trace events #{events}, trace bytes #{bytes}"
    )

    Enum.each(Run.unchecked_names(cmp), &IO.puts/1)
    assert cmp.outcome == [] and cmp.trace == []
    assert cmp.checked > 0
  end

  test "the shipped NIF agrees with the instrumented base on self-contained cases", ctx do
    {single, pairs} = Enum.split_with(ctx.cases, &(&1.problem == ""))
    {checked, unchecked} = Enum.split_with(single, &(Run.unchecked(&1, ctx.base[&1.id]) == []))
    shipped = Map.new(checked, &{&1.id, Run.shipped(&1)})

    diffs = fn base ->
      for c <- checked, shipped[c.id] != {base[c.id].status, base[c.id].plan}, do: c.id
    end

    planted = Enum.find(checked, &(ctx.base[&1.id].plan not in ["", "[]"]))

    IO.puts(
      "shipped Taskweft.NIF.plan vs base: checked #{length(checked)}, UNCHECKED #{length(unchecked)}, differ #{length(diffs.(ctx.base))}; domain+problem pairs not loadable through plan/1: #{length(pairs)}"
    )

    assert diffs.(ctx.base) == []
    assert diffs.(Map.update!(ctx.base, planted.id, &%{&1 | plan: "[]"})) == [planted.id]
  end

  test "goldens agree with base and a truncated golden is rejected", ctx do
    goldens = Enum.filter(ctx.cases, &(&1.family == "golden"))

    agree? = fn c, expected ->
      ctx.base[c.id].status == "ok" and Corpus.golden_match?(ctx.base[c.id].plan, expected)
    end

    {agree, disagree} = Enum.split_with(goldens, &agree?.(&1, &1.expected))
    {truncatable, empty} = Enum.split_with(agree, &(&1.expected != []))
    accepted = Enum.filter(truncatable, &agree?.(&1, Enum.drop(&1.expected, -1)))

    IO.puts(
      "goldens: #{length(agree)}/#{length(goldens)} agree; truncation control rejected #{length(truncatable) - length(accepted)}/#{length(truncatable)} (#{length(empty)} pin an empty plan)"
    )

    for c <- disagree,
        do:
          IO.puts(
            "  DISAGREE #{c.id}: golden #{length(c.expected)} steps, base #{ctx.base[c.id].status} #{ctx.base[c.id].plan}"
          )

    assert Enum.map(disagree, & &1.id) == @golden_disagreements
    assert truncatable != [] and accepted == []
  end

  for variant <- [:norequeue, :nocache, :fuel399] do
    test "control #{variant} changes at least one checked plan and trace", ctx do
      {us, runs} =
        :timer.tc(fn -> Run.run(ctx.builds[unquote(variant)], ctx.cases, @variant_budget_ms) end)

      cmp = Run.compare(ctx.cases, ctx.base, runs)

      moves =
        Enum.frequencies(for id <- cmp.outcome, do: "#{ctx.base[id].status}->#{runs[id].status}")

      IO.puts(
        Run.summary("control #{unquote(variant)} (#{div(us, 1000)} ms)", cmp) <>
          " #{inspect(moves)}"
      )

      assert cmp.outcome != [] and cmp.trace != []
    end
  end

  test "the collision counter fires on a build with 4-bit memo keys", ctx do
    runs = Run.run(ctx.builds.collide, ctx.cases, @variant_budget_ms)
    hit = Enum.count(runs, fn {_, r} -> r.collisions > 0 end)

    IO.puts(
      "collision control: #{hit} cases flagged; base flags #{Enum.count(ctx.base, fn {_, r} -> r.collisions > 0 end)}"
    )

    assert hit > 0
  end

  test "the budget counter fires on a zero budget", ctx do
    c = Enum.max_by(ctx.cases, &elem(ctx.base[&1.id].trace, 1))
    r = Run.call(ctx.builds.base, c, 0)
    IO.puts("budget control: #{c.id} with 0 ms -> #{r.status}, budget hit #{r.budget}")
    assert :budget in Run.unchecked(c, r)
  end

  test "a math/random domain is unchecked" do
    planted = %{"methods" => %{"m" => [%{"check" => [%{"eval" => %{"type" => "math/random"}}]}]}}
    assert Corpus.random_node?(planted)

    refute Corpus.random_node?(
             Jason.decode!(File.read!("test/differential/fixtures/domains/blocks_world.jsonld"))
           )

    assert Run.unchecked(%{random: true}, %{budget: false, collisions: 0}) == [:random]
  end

  test "a planner anchor that moved fails the build" do
    assert_raise RuntimeError, ~r/found 0 times/, fn ->
      Build.patch("int x;", [{"absent", "y", 1}])
    end

    assert_raise RuntimeError, ~r/found 2 times/, fn -> Build.patch("a a", [{"a", "b", 1}]) end
  end
end
