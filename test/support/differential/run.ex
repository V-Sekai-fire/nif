defmodule Taskweft.Differential.Run do
  @moduledoc """
  Runs the corpus through one build and compares two runs case by case. A case
  that hit the wall-clock budget, saw a memo-key hash collision, or loads a
  math/random domain is UNCHECKED on that pair and never counts as agreeing.
  """

  def run(mod, cases, budget_ms, opts \\ []) do
    trace_dir = opts[:traces]
    if trace_dir, do: File.mkdir_p!(trace_dir)
    one = fn c -> {c.id, call(mod, c, budget_ms, trace_path(trace_dir, c))} end

    if Keyword.get(opts, :parallel, true) do
      cases
      |> Task.async_stream(one, max_concurrency: System.schedulers_online(), timeout: :infinity)
      |> Map.new(fn {:ok, r} -> r end)
    else
      Map.new(cases, one)
    end
  end

  def call(mod, c, budget_ms, trace \\ "") do
    {status, plan, hash, events, bytes, budget, collisions, us} =
      mod.plan(c.domain, c.problem, budget_ms, trace)

    %{
      status: status,
      plan: plan,
      trace: {hash, events, bytes},
      budget: budget,
      collisions: collisions,
      us: us
    }
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
    for {reason, true} <- [budget: r.budget, collision: r.collisions > 0, random: c.random],
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

  def summary(name, cmp) do
    counts = cmp.unchecked |> Map.values() |> List.flatten() |> Enum.frequencies()

    "#{name}: checked #{cmp.checked}, UNCHECKED #{map_size(cmp.unchecked)} " <>
      "(budget #{counts[:budget] || 0}, collision #{counts[:collision] || 0}, math/random #{counts[:random] || 0}), " <>
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
