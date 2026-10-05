defmodule Taskweft.Differential.Corpus do
  @moduledoc """
  The enumerated differential corpus: the runnable goldens, 480 generated
  blocks-world problems from a fixed seed, and the fuel family k = 130..134.
  """

  import Bitwise, only: [band: 2, bxor: 2, bsr: 2]
  alias Jason.OrderedObject, as: Obj

  @fixtures Path.expand("../../differential/fixtures", __DIR__)
  @seed 0x2292_2044_0007
  @mask 0xFFFF_FFFF_FFFF_FFFF

  @unreachable_goldens [
    {"issue_graph", "domain exists only as the taskweft DSL"},
    {"issue_graph_cycle", "domain exists only as the taskweft DSL"},
    {"skill_allocation__skill_allocation_mzn_1m_2", "domain exists only as the taskweft DSL"},
    {"skill_allocation__skill_allocation_mzn_2m_2", "domain exists only as the taskweft DSL"},
    {"skill_allocation__skill_allocation_mzn_2w_2", "domain exists only as the taskweft DSL"},
    {"skill_allocation__skill_allocation_mzn_3m_3", "domain exists only as the taskweft DSL"},
    {"skill_allocation__skill_allocation_mzn_5d_1", "domain exists only as the taskweft DSL"}
  ]

  def unreachable_goldens, do: @unreachable_goldens

  def all(dir) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    Enum.map(goldens() ++ generated(dir) ++ fuel(dir), &Map.put(&1, :random, random_domain?(&1)))
  end

  def digest(cases) do
    cases
    |> Enum.flat_map(fn c -> [c.id, read(c.domain), read(c.problem)] end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp read(""), do: ""
  defp read(path), do: File.read!(path)

  def goldens do
    for path <- Path.wildcard(Path.join(@fixtures, "expected/*_expected.json")) |> Enum.sort() do
      name = Path.basename(path, "_expected.json")

      {domain, problem} =
        case String.split(name, "__") do
          [d, p] -> {fixture("domains/#{d}.jsonld"), fixture("problems/#{p}.jsonld")}
          [d] -> {fixture("domains/#{d}.jsonld"), ""}
        end

      %{
        id: "golden/#{name}",
        family: "golden",
        domain: domain,
        problem: problem,
        expected: Jason.decode!(File.read!(path))["plan"]
      }
    end
  end

  defp fixture(rel) do
    path = Path.join(@fixtures, rel)
    File.exists?(path) || raise "golden fixture missing: #{rel}"
    path
  end

  def golden_match?(plan_json, expected), do: Jason.decode!(plan_json) == expected

  def random_domain?(%{domain: d, problem: p}) do
    Enum.any?([d, p], &(&1 != "" and random_node?(Jason.decode!(File.read!(&1)))))
  end

  def random_node?(%{"type" => t} = m) when is_binary(t) do
    List.last(String.split(t, "/")) == "random" or Enum.any?(Map.values(m), &random_node?/1)
  end

  def random_node?(m) when is_map(m), do: Enum.any?(Map.values(m), &random_node?/1)
  def random_node?(l) when is_list(l), do: Enum.any?(l, &random_node?/1)
  def random_node?(_), do: false

  defp blocks_world_variants do
    bw =
      Jason.decode!(File.read!(Path.join(@fixtures, "domains/blocks_world.jsonld")),
        objects: :ordered_objects
      )

    for g <- [false, true], p <- [false, true] do
      bw
      |> reverse_if(g, ["methods", "get", "alternatives"])
      |> reverse_if(p, ["methods", "put", "alternatives"])
    end
  end

  defp reverse_if(doc, false, _), do: doc
  defp reverse_if(doc, true, path), do: update_in(doc, path, &Enum.reverse/1)

  def generated(dir) do
    domains = blocks_world_variants()

    {cases, _} =
      Enum.map_reduce(1..480, @seed, fn i, rng ->
        kind = Enum.at([:multigoal, :goal, :calls], rem(i, 3))
        {vars, todo, rng} = problem(3 + rem(div(i, 3), 3), kind, rng)
        doc = Enum.at(domains, rem(div(i, 9), 4))
        path = write(dir, "gen_#{i}", doc, vars, todo)
        {%{id: "gen/#{kind}/#{i}", family: "gen/#{kind}", domain: path, problem: ""}, rng}
      end)

    cases
  end

  def fuel(dir) do
    [doc | _] = blocks_world_variants()
    on_table = towers_state([["b0"], ["b1"], ["b2"]])

    for k <- 130..134, j <- 0..2 do
      tail =
        case j do
          0 -> []
          1 -> [["get", "b0"], ["a_putdown", "b0"]]
          2 -> [["get", "b0"], ["put", "b0", "table"]]
        end

      todo = List.duplicate(["move_one", "b0", "table"], k) ++ tail
      path = write(dir, "fuel_#{k}_#{j}", doc, on_table, todo)
      %{id: "fuel/k=#{k},j=#{j}", family: "fuel", domain: path, problem: ""}
    end
  end

  defp write(dir, name, doc, vars, todo) do
    path = Path.join(dir, name <> ".jsonld")

    File.write!(
      path,
      Jason.encode!(doc |> put_in(["variables"], vars) |> put_in(["todo_list"], todo))
    )

    path
  end

  defp problem(n, kind, rng) do
    blocks = for i <- 0..(n - 1), do: "b#{i}"
    {start, rng} = towers(blocks, rng)
    {target, rng} = towers(blocks, rng)
    goal = pos_of(target)

    {todo, rng} =
      case kind do
        :multigoal ->
          {[obj([{"multigoal", obj([{"pos", obj(goal)}])}])], rng}

        :goal ->
          {order, rng} = shuffle(goal, rng)

          {[
             obj([{"goal", for({b, d} <- order, do: obj([{"pointer", "/pos/#{b}"}, {"eq", d}]))}])
           ], rng}

        :calls ->
          {count, rng} = uniform(4, rng)

          Enum.map_reduce(1..(count + 1), rng, fn _, rng ->
            {bi, rng} = uniform(n, rng)
            b = Enum.at(blocks, bi)
            dests = ["table" | blocks -- [b]]
            {di, rng} = uniform(length(dests), rng)
            {["move_one", b, Enum.at(dests, di)], rng}
          end)
      end

    {towers_state(start), todo, rng}
  end

  defp towers_state(ts) do
    clear = for t <- ts, {b, i} <- Enum.with_index(t), do: {b, i == length(t) - 1}

    [
      obj([{"name", "pos"}, {"type", "ref"}, {"init", obj(Enum.sort(pos_of(ts)))}]),
      obj([{"name", "clear"}, {"type", "bool"}, {"init", obj(Enum.sort(clear))}]),
      obj([{"name", "holding"}, {"type", "bool"}, {"init", obj([{"hand", false}])}])
    ]
  end

  defp towers(blocks, rng) do
    {order, rng} = shuffle(blocks, rng)

    Enum.reduce(order, {[], rng}, fn b, {acc, rng} ->
      {r, rng} = uniform(3, rng)

      if acc == [] or r == 0 do
        {[[b] | acc], rng}
      else
        {i, rng} = uniform(length(acc), rng)
        {List.update_at(acc, i, &(&1 ++ [b])), rng}
      end
    end)
  end

  defp pos_of(ts) do
    Enum.sort(
      for t <- ts,
          {b, i} <- Enum.with_index(t),
          do: {b, if(i == 0, do: "table", else: Enum.at(t, i - 1))}
    )
  end

  defp shuffle(list, rng) do
    {keyed, rng} =
      Enum.map_reduce(list, rng, fn x, rng ->
        {k, rng} = next(rng)
        {{k, x}, rng}
      end)

    {keyed |> Enum.sort() |> Enum.map(&elem(&1, 1)), rng}
  end

  defp uniform(n, rng) do
    {z, rng} = next(rng)
    {rem(z, n), rng}
  end

  # splitmix64, so the corpus does not depend on the OTP :rand implementation.
  defp next(s) do
    s = band(s + 0x9E3779B97F4A7C15, @mask)
    z = band(bxor(s, bsr(s, 30)) * 0xBF58476D1CE4E5B9, @mask)
    z = band(bxor(z, bsr(z, 27)) * 0x94D049BB133111EB, @mask)
    {bxor(z, bsr(z, 31)), s}
  end

  defp obj(pairs), do: Obj.new(pairs)
end
