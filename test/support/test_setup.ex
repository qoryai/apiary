defmodule Apiary.TestSetup do
  @moduledoc """
  TestSetup starts a suite of tests: the core's, from its `test/test_helper.exs`, or an
  edition's, from its own, which gives the tags it excludes of its own:

      Apiary.TestSetup.start!(exclude: [:contract])

  `start!/1` does, in order:

  - **The features.** The suite with QORY_FEATURES unset or blank, CI's "every feature",
    runs with every feature (`Apiary.Features.all/0`): the opt-in ones too
    (`Apiary.Features.opt_in/0`), which an instance launched so leaves off.
  - **The tags it leaves out.**
    - A test tagged `needs: feature` exercises that feature; the suite runs in CI under
      more than one QORY_FEATURES, and a run without the feature leaves such tests out
      (`{:needs, feature}`). A test that exercises two features or more is tagged
      `needs: [feature_1, feature_2]`, and a run with any of them off leaves it out.
      ExUnit keeps one value for a tag key, so a `@tag needs:` on a test replaces the
      module's `@moduletag needs:`: a test that adds a feature to the module's lists all
      of them. ExUnit's filter compares a tag value as text, which raises for a list of
      atoms, so `__before_compile__/1` replaces a list by its first feature that is off,
      or by nil when none is, in the tags of the module's tests (`needs_tag/2`).
      `Apiary.DataCase` and `ApiaryWeb.ConnCase` set it with `@before_compile
      Apiary.TestSetup`, and so does every template built on them. A module that has
      `use ExUnit.Case` alone sets the same line after it to take a list. Without the
      line, in a run with a feature off, ExUnit logs an ArgumentError, leaves every test of
      the module out of the result, and `mix test` exits 0. `unhooked/0` finds such
      modules, and a suite checks it with one test.
    - A test tagged `with_features:` runs under the features it names, whatever the
      suite's (`Apiary.DataCase.setup_features/1`), and so passes or fails alike under
      each: it runs where the suite has every feature, and a run with fewer leaves it out
      (`:with_features`).
    - A test tagged `:feature_sets` reads the instance's features while it runs, before it
      sets them: in its body, a `setup` or a helper. CI runs every test once with every
      feature, then `mix test --only feature_sets` under each other feature set, so the
      tagged tests alone run again. ExUnit lets the include of `--only` win over an
      exclude, so `__before_compile__/1` drops `:feature_sets` from a test the suite
      leaves out, such as one whose `needs:` has a feature that is off, and such a run
      leaves it out too (`run_tags/2`). A test tagged `with_features:` runs once, in the
      run with every feature on, under the features it lists, and takes no
      `:feature_sets`. `Apiary.FeatureSetsScan` finds the test files that read the
      features without the tag.
    - The tests tagged `:load` measure the receiver under a gateway's backlog, for long and
      outside the sandbox: they run only when asked for, with `mix test --only load`.
    - The tests tagged `:database_tls` connect to a Postgres that serves TLS, which CI's
      job "Database over TLS" starts: they run only when asked for, with
      `mix test --only database_tls`.
  - **ExUnit**, started with those excludes. A LiveView's async assigns and a PubSub
    message arrive in milliseconds on an idle machine and not within the default 100 ms
    under a full, parallel suite: `render_async` and `assert_receive` wait up to five
    seconds (`assert_receive_timeout: 5_000`), and return as soon as there is something.
  - **The instance.** It is set up, committed before the sandbox takes over: a sign-up in
    a test is a later one (`Apiary.OrganisationsFixtures.ensure_instance_organisation!/0`,
    which asks the configured edition whether it is set up, and sets it up through it).
  - **The sandbox**, in the manual mode: each test checks out its own connection
    (`Apiary.DataCase.setup_sandbox/1`).

  Nothing in it is the core's edition's own: the features, the instance and its set-up
  are asked of the configured edition, as the product asks them.
  """

  @doc """
  start!/1 starts the suite as the module says, and returns `:ok`.

  Options:

  - `exclude:`, more tags to leave out: they come first, before the ones `start!/1` leaves
    out itself, which it always does;
  - any other option is `ExUnit.start/1`'s and passes through to it: one that
    `start!/1` sets too, `assert_receive_timeout:`, is the caller's where it gives one.
  """
  @spec start!(keyword) :: :ok
  def start!(opts \\ []) do
    {exclude, opts} = Keyword.pop(opts, :exclude, [])

    if String.trim(Application.get_env(:apiary, :features_setting) || "") == "" do
      Application.put_env(:apiary, :features, Apiary.Features.all())
    end

    off = Apiary.Features.all() -- Apiary.Features.enabled()
    :persistent_term.put({__MODULE__, :off}, off)
    :persistent_term.put({__MODULE__, :exclude}, List.wrap(exclude))

    [assert_receive_timeout: 5_000]
    |> Keyword.merge(opts)
    |> Keyword.put(:exclude, exclude(off))
    |> ExUnit.start()

    Apiary.OrganisationsFixtures.ensure_instance_organisation!()

    Ecto.Adapters.SQL.Sandbox.mode(Apiary.Repo, :manual)
  end

  @doc """
  off/0 is the features the suite runs without: those of `Apiary.Features.all/0` that
  `Apiary.Features.enabled/0` lacked as `start!/1` ran. A test that switches the features
  for its run (`with_features:`) does not change it. When `start!/1` has not run, it is
  computed from `Apiary.Features.enabled/0` at each call.
  """
  @spec off() :: [atom]
  def off do
    :persistent_term.get({__MODULE__, :off}, nil) ||
      Apiary.Features.all() -- Apiary.Features.enabled()
  end

  @doc """
  unhooked/0 is `{module, test name}` for each test, in the loaded modules of ExUnit
  tests, whose `needs:` is a list: the module lacks `@before_compile Apiary.TestSetup`.
  In a run with a feature off ExUnit logs an ArgumentError, leaves every test of such a
  module out of the result, and `mix test` exits 0. A suite asserts that `unhooked/0` is
  empty once its test modules are loaded, in a test of a module that is not async.
  """
  @spec unhooked() :: [{module, atom}]
  def unhooked do
    for {module, _} <- :code.all_loaded(),
        function_exported?(module, :__ex_unit__, 0),
        test <- module.__ex_unit__().tests,
        is_list(test.tags[:needs]),
        do: {module, test.name}
  end

  @doc """
  needs_tag/2 is the value ExUnit's filter takes for a test's `needs:`, given the
  features that are `off`: a single feature as it is, and for a list the first feature
  of it that is off, or nil when none is. Raises `ArgumentError` for a list with an
  element that is no atom.
  """
  @spec needs_tag(atom | [atom], [atom]) :: atom
  def needs_tag(needs, off) when is_list(needs) do
    if not Enum.all?(needs, &is_atom/1) do
      raise ArgumentError, "needs: is a feature or a list of features, got #{inspect(needs)}"
    end

    Enum.find(needs, &(&1 in off))
  end

  def needs_tag(needs, _off), do: needs

  @doc """
  exclude/1 is the tags the suite leaves out, given the features that are `off`: the
  `exclude:` given to `start!/1`, then `{:needs, feature}` for each feature that is off,
  `:with_features` when one is, `:load` and `:database_tls`.
  """
  @spec exclude([atom]) :: list
  def exclude(off) do
    :persistent_term.get({__MODULE__, :exclude}, []) ++
      for(feature <- off, do: {:needs, feature}) ++
      if(off == [], do: [], else: [:with_features]) ++
      [:load, :database_tls]
  end

  @doc """
  run_tags/2 is a test's tags as ExUnit's filter takes them, given the features that are
  `off`: a list in `needs:` becomes its value of `needs_tag/2`, and `:feature_sets` is
  dropped from a test that `exclude/1` leaves out. `mix test --only feature_sets` includes
  each tagged test, and ExUnit's include wins over an exclude: without the drop, the run
  would include a test whose feature is off, a `:load` test or a `:database_tls` test.
  """
  @spec run_tags(map, [atom]) :: map
  def run_tags(tags, off) do
    tags =
      case tags do
        %{needs: needs} when is_list(needs) -> %{tags | needs: needs_tag(needs, off)}
        tags -> tags
      end

    case ExUnit.Filters.eval([], exclude(off), tags, []) do
      {:excluded, _reason} -> Map.delete(tags, :feature_sets)
      _run_or_skipped -> tags
    end
  end

  @doc false
  # Runs after the `__before_compile__` of ExUnit.Case, so `super()` is the `__ex_unit__/0`
  # that one defines. The runner calls it and filters on the tags of the tests it returns.
  defmacro __before_compile__(_env) do
    quote do
      defoverridable __ex_unit__: 0

      def __ex_unit__ do
        off = Apiary.TestSetup.off()
        module = super()

        tests =
          Enum.map(module.tests, &%{&1 | tags: Apiary.TestSetup.run_tags(&1.tags, off)})

        %{module | tests: tests}
      end
    end
  end
end
