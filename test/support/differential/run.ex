defmodule Taskweft.Differential.Run do
  @moduledoc """
  Runs the corpus through one build and compares two runs case by case. Every
  run has a step budget, counted in planner budget probes, so which cases
  exhaust it does not depend on the machine; the wall clock is only a backstop.
  A case that exhausted either budget, saw a memo-key hash collision, or loads
  a math/random domain is UNCHECKED on that pair and never counts as agreeing.
  """

  @backstop_ms 60_000
  @collision_kinds [:fail_cache, :success_cache, :method_stats, :decomposition]

  def run(mod, cases, steps, opts \\ []) do
    trace_dir = opts[:traces]
    if trace_dir, do: File.mkdir_p!(trace_dir)
    one = fn c -> {c.id, call(mod, c, steps, trace: trace_path(trace_dir, c))} end

    if Keyword.get(opts, :parallel, true) do
      cases
      |> Task.async_stream(one, max_concurrency: System.schedulers_online(), timeout: :infinity)
      |> Map.new(fn {:ok, r} -> r end)
    else
      Map.new(cases, one)
    end
  end

  def call(mod, c, steps, opts \\ []) do
    ms = Keyword.get(opts, :ms, @backstop_ms)

    {status, plan, hash, events, bytes, budget, used, steps_hit, kinds, us} =
      mod.plan(c.domain, c.problem, ms, steps, Keyword.get(opts, :trace, ""))

    %{
      status: status,
      plan: plan,
      trace: {hash, events, bytes},
      budget: budget,
      steps: used,
      steps_hit: steps_hit,
      collisions: Enum.sum(kinds),
      collision_kinds: Map.new(Enum.zip(@collision_kinds, kinds)),
      us: us
    }
  end

  def flagged_by_kind(runs) do
    Map.new(@collision_kinds, fn k ->
      {k, Enum.count(runs, fn {_, r} -> r.collision_kinds[k] > 0 end)}
    end)
  end

  def shipped(c) do
    {"ok", Taskweft.NIF.plan(File.read!(c.domain))}
  rescue
    e in RuntimeError ->
      {if(e.message == "failed_to_load_domain", do: "load_error", else: e.message), ""}
  end

  def trace_path(nil, _), do: ""

  def trace_path(dir, c),
    do: Path.join(dir, String.replace(c.id, ~r/[^A-Za-z0-9_.-]/, "_") <> ".trace")

  def unchecked(c, r) do
    for {reason, true} <- [
          budget: r.budget,
          steps: r.steps_hit,
          collision: r.collisions > 0,
          random: c.random
        ],
        do: reason
  end

  def compare(cases, a, b) do
    Enum.reduce(cases, %{checked: 0, unchecked: %{}, outcome: [], trace: []}, fn c, acc ->
      {ra, rb} = {Map.fetch!(a, c.id), Map.fetch!(b, c.id)}

      case Enum.uniq(unchecked(c, ra) ++ unchecked(c, rb)) do
        [] ->
          acc = %{acc | checked: acc.checked + 1}

          acc =
            if {ra.status, ra.plan} != {rb.status, rb.plan},
              do: %{acc | outcome: [c.id | acc.outcome]},
              else: acc

          if ra.trace != rb.trace, do: %{acc | trace: [c.id | acc.trace]}, else: acc

        reasons ->
          %{acc | unchecked: Map.put(acc.unchecked, c.id, reasons)}
      end
    end)
  end

  def coverage(cmp) do
    %{
      checked: cmp.checked,
      unchecked: cmp.unchecked |> Map.values() |> List.flatten() |> Enum.frequencies()
    }
  end

  def check_coverage(cmp, expected) do
    case coverage(cmp) do
      ^expected -> :ok
      actual -> {:error, "coverage #{inspect(actual)}, expected #{inspect(expected)}"}
    end
  end

  def summary(name, cmp) do
    counts = coverage(cmp).unchecked

    "#{name}: checked #{cmp.checked}, UNCHECKED #{map_size(cmp.unchecked)} " <>
      "(budget #{counts[:budget] || 0}, steps #{counts[:steps] || 0}, collision #{counts[:collision] || 0}, math/random #{counts[:random] || 0}), " <>
      "outcome changed #{length(cmp.outcome)}, trace changed #{length(cmp.trace)}"
  end

  def unchecked_names(cmp) do
    for {id, reasons} <- Enum.sort(cmp.unchecked),
        do: "  UNCHECKED #{id} #{Enum.join(reasons, ",")}"
  end

  def percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, div(length(sorted) * p, 100)))
  end
end
