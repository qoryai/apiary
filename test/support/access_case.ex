defmodule Apiary.AccessCase do
  @moduledoc """
  AccessCase is the access test's table as data: every action of `Apiary.Access`, and the
  kinds of actor that matter. A module of rows gives, for its edition, its actors, how to
  make them, and a row per action, `{action, yes: actors}`, with the actors that may.
  `use`d with the rows modules of the core and of an edition, in that order:

      use Apiary.AccessCase, rows: [Apiary.AccessRows, MyEdition.AccessRows]

  it generates three tests: every action has a row and every row an action, every row
  lists only actors of the modules, and the role table lists only actions. The rules of
  `Apiary.Access.can?/3` and `Apiary.Access.authorize/3` are tested in a test module that
  asks each rule once (`test/apiary/access_test.exs` for the core), not every action of
  every actor.

  `covers:` sets which actions the rows must cover: `:all`, the default, every action of
  `Apiary.Access`; `:core`, the core's actions alone (`actions/1`). The core's test is
  `use Apiary.AccessCase, rows: [Apiary.AccessRows], covers: :core`. Run with an edition, the
  rows of the edition's kit (`c:Apiary.EditionKit.access_rows/0`) answer too, where the
  edition changes what the core's actors may. The edition's test gives the core's rows and
  the edition's, and covers every action.

  The tests of a test module may ask the same answers: `answering/1` and `rows/1` for the
  table its rows and the kit's make together, `actions/1` for the actions a file covers,
  `setup_actors/1` for the actors, `assert_row/2` to ask one action of one actor as the
  rows say, and `refusal/4` for why an actor may not.

  A rows module implements:

  - `actors/0`, its actors;
  - `rows/0`, `[{action, keyword}]`: `yes:`, the actors that may, and `on:`, what the
    action is asked of when it is not what `Apiary.Access.Action` says (`asked_of`), or
    `:adapter`, the adapter beside the place, a node of kind `:adapter` of the instance
    (the place's `adapter`). A
    row of an action another module has too adds its `yes:` to the other's: an edition's
    row of a core action names the edition's actors that may;
  - `setup/1`, given what the modules before it made (`%{places: %{}, scopes: %{}}`),
    the places and the scopes it adds: a place is a map with `organisation` and
    `workspace`, and a scope is an actor's;
  - `place/2`, the place `actor` asks `action` in, for its own actors, else nil;
  - `refusal/3`, why `actor` may not take `action` on `subject`, `:not_found` or
    `:forbidden`, where its edition decides it; nil leaves it to the others. The last
    module to answer wins; with none, it is forbidden.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Apiary.Access
  alias Apiary.Organisations.Organisation

  using opts do
    opts = Keyword.validate!(opts, [:rows, covers: :all])
    modules = Keyword.fetch!(opts, :rows)
    covers = Keyword.fetch!(opts, :covers)

    quote bind_quoted: [modules: modules, covers: covers] do
      use Apiary.DataCase, async: false

      # The rules are asked on an instance with every feature, whatever the suite runs
      # under; a test that takes one away is tagged `with_features:`.
      @moduletag with_features: Apiary.Features.all()

      @access_covers covers
      @access_rows Apiary.AccessCase.rows(modules)
      # Who may, as the modules and the edition's kit say it together.
      @access_answering Apiary.AccessCase.answering(modules)

      test "every action has a row, and every row an action" do
        assert Enum.sort(Enum.map(@access_rows, &elem(&1, 0))) ==
                 Enum.sort(Apiary.AccessCase.actions(@access_covers))
      end

      test "every row names only the actors of the table" do
        for {action, row} <- @access_rows, actor <- row[:yes] do
          assert actor in Apiary.AccessCase.actors(@access_answering),
                 "#{action} names #{inspect(actor)}, which is no actor"
        end
      end

      test "the role table names only actions of the list" do
        for {role, actions} <- Apiary.Access.roles(), action <- actions do
          assert action in Apiary.Access.actions(), "#{role} names #{inspect(action)}"
        end
      end
    end
  end

  @doc """
  actions/1 is the actions a test's rows cover: `:all`, every action of `Apiary.Access`;
  `:core`, the core's own, without the edition's. The edition's own are
  `actions(:all) -- actions(:core)`.
  """
  @spec actions(:all | :core) :: [Access.action()]
  def actions(:all), do: Access.actions()
  def actions(:core), do: Access.actions() -- Enum.map(Apiary.Edition.actions(), & &1.name)

  @doc """
  answering/1 is `modules` and the rows modules of the edition's kit
  (`c:Apiary.EditionKit.access_rows/0`), each once: what answers who may, where the
  edition changes what the actors of `modules` may.
  """
  @spec answering([module]) :: [module]
  def answering(modules), do: Enum.uniq(modules ++ Apiary.EditionKit.access_rows())

  @doc """
  rows/1 is the rows of `modules` merged, in their order: a row of an action an earlier
  module has adds its `yes:` to it, and its other keys win.
  """
  @spec rows([module]) :: [{Access.action(), keyword}]
  def rows(modules) do
    Enum.reduce(modules, [], fn module, rows ->
      Enum.reduce(module.rows(), rows, fn {action, row}, rows ->
        case List.keyfind(rows, action, 0) do
          nil ->
            rows ++ [{action, row}]

          {^action, before} ->
            merged =
              before
              |> Keyword.merge(row)
              |> Keyword.put(:yes, Enum.uniq(before[:yes] ++ row[:yes]))

            List.keyreplace(rows, action, 0, {action, merged})
        end
      end)
    end)
  end

  @doc "actors/1 is the actors of `modules`, in their order."
  @spec actors([module]) :: [atom]
  def actors(modules), do: Enum.flat_map(modules, & &1.actors())

  @doc """
  setup_actors/1 makes the places and the scopes of `modules`, each given what the ones
  before it made: `%{places: places, scopes: scopes}`.
  """
  @spec setup_actors([module]) :: %{places: map, scopes: map}
  def setup_actors(modules) do
    Enum.reduce(modules, %{places: %{}, scopes: %{}}, fn module, made ->
      %{places: places, scopes: scopes} = module.setup(made)
      %{places: Map.merge(made.places, places), scopes: Map.merge(made.scopes, scopes)}
    end)
  end

  @doc """
  assert_row/2 asks the test's `action` of its `actor`, in the places and scopes of
  `setup_actors/1`, and asserts `answer`, by `can?/3` and `authorize/3` alike, and why not
  where it is no. `ctx` has `action`, `actor`, `answer`, `places` and `scopes`.
  """
  @spec assert_row(map, [module]) :: :ok
  def assert_row(%{action: action, actor: actor, answer: answer} = ctx, modules) do
    {scope, subject} = asked(ctx, modules, action, actor)

    {can?, authorized} =
      case actor do
        :feature_off -> without_feature(action, fn -> answers(scope, action, subject) end)
        :hidden -> hiding_feature(action, scope, fn scope -> answers(scope, action, subject) end)
        _actor -> answers(scope, action, subject)
      end

    assert can? == answer, "can?/3 says #{can?}"
    assert authorized == :ok == answer, "authorize/3 says #{inspect(authorized)}"

    unless answer do
      assert authorized == {:error, refusal(modules, action, actor, subject)}
    end

    :ok
  end

  # The scope that asks and what it asks about. `feature_off` and `hidden` ask as whoever
  # the action is for, an owner, an adapter's key, an access key, a pool's key or the
  # instance; everyone else as themselves, in the place their module says, of what the
  # action is asked of there: the organisation, the workspace, a new organisation, or the
  # member's account, another than the asker's.
  defp asked(ctx, modules, action, actor) when actor in [:feature_off, :hidden] do
    actor =
      cond do
        :adapter_key in Access.action(action).roles -> :adapter_key
        :access_key in Access.action(action).roles -> :access_key
        :pool_key in Access.action(action).roles -> :pool_key
        :instance in Access.action(action).roles -> :instance
        true -> :owner
      end

    {ctx.scopes[actor], subject(ctx, modules, action, ctx.places.home)}
  end

  defp asked(ctx, modules, action, actor) do
    place = Enum.find_value(modules, & &1.place(action, actor)) || :home
    {ctx.scopes[actor], subject(ctx, modules, action, ctx.places[place])}
  end

  defp subject(ctx, modules, action, place) do
    on =
      modules
      |> rows()
      |> List.keyfind(action, 0)
      |> elem(1)
      |> Keyword.get(:on, Access.action(action).asked_of)

    case on do
      :organisation -> place.organisation
      :workspace -> place.workspace
      :new_organisation -> %Organisation{}
      :account -> ctx.scopes.member.user
      :adapter -> place.adapter
    end
  end

  @doc """
  refusal/4 is why `actor` may not take `action` on `subject`, as `modules` say it
  (`refusal/3` of each): the last module to answer, else `:forbidden`.
  """
  @spec refusal([module], Access.action(), atom, term) :: Access.reason()
  def refusal(modules, action, actor, subject) do
    modules
    |> Enum.map(& &1.refusal(action, actor, subject))
    |> Enum.reject(&is_nil/1)
    |> List.last(:forbidden)
  end

  defp answers(scope, action, subject),
    do: {Access.can?(scope, action, subject), Access.authorize(scope, action, subject)}

  # Runs `fun` on an instance without the action's feature, and without the features that
  # need it. An action every instance has is asked on the fewest features an instance can
  # have. `observability` is on in every instance a boot accepts; its rows take it away
  # all the same, to show the answer reads it.
  defp without_feature(action, fun) do
    features =
      case Access.feature(action) do
        nil ->
          [:observability]

        off ->
          Enum.reject(
            Apiary.Features.all(),
            &(&1 == off or off in Apiary.Features.needs(&1))
          )
      end

    previous = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, features)

    try do
      fun.()
    after
      Application.put_env(:apiary, :features, previous)
    end
  end

  # Runs `fun` with the scope read again where the edition hides from people the part the
  # action belongs to, of its feature or of none, else the action's feature
  # (`Apiary.Access.shown_as/1`, `Apiary.EditionStubs.HidesNamed`), as a page's scope
  # carries it; an action of no feature and no part hides nothing.
  defp hiding_feature(action, scope, fun) do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
    :ok = Apiary.EditionStubs.HidesNamed.put(List.wrap(Access.shown_as(action)))

    fun.(Access.reload(scope))
  end
end
