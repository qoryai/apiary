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
      (`{:needs, feature}`).
    - A test tagged `with_features:` runs under the features it names, whatever the
      suite's (`Apiary.DataCase.setup_features/1`), and so passes or fails alike under
      each: it runs where the suite has every feature, and a run with fewer leaves it out
      (`:with_features`).
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

    exclude =
      List.wrap(exclude) ++
        for(feature <- off, do: {:needs, feature}) ++
        if(off == [], do: [], else: [:with_features]) ++
        [:load, :database_tls]

    [assert_receive_timeout: 5_000]
    |> Keyword.merge(opts)
    |> Keyword.put(:exclude, exclude)
    |> ExUnit.start()

    Apiary.OrganisationsFixtures.ensure_instance_organisation!()

    Ecto.Adapters.SQL.Sandbox.mode(Apiary.Repo, :manual)
  end
end
