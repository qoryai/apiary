defmodule ApiaryWeb.Features do
  @moduledoc """
  The web side of `Apiary.Features`: a page or an endpoint that belongs to a feature says so
  with `use ApiaryWeb.Features, :security`, and answers as a path that does not exist when
  the feature is off, or hidden from the person who asks. Not *forbidden*: a feature that is
  off or hidden is absent.

  The `use` defines `__feature__/0`. `ApiaryWeb.Features.Routes`, in the endpoint, reads it
  for the route a request matches and answers for the instance before any pipeline runs;
  the router's test reads it so that no route is left without a feature or an explicit
  place among the routes every instance has. The `use` also adds a gate: an `on_mount` hook
  in a LiveView, which is what a live navigation meets, and a plug in a controller. A
  person's scope is asked `Apiary.Features.visible?/2`, what the person is shown; the
  access key of a signed request of the server contract is asked `Apiary.Features.on?/1`,
  the instance's switch, so a node is served whatever a level below the instance shows.
  `page_shown?/2` asks a page's gate as the hook does, for a page that is already open.

  A page that belongs to more than one feature names them with `any:`,
  `use ApiaryWeb.Features, any: [:security, :secrets]`: it is there when at least one of
  them is, and absent, as above, when none is. `__feature__/0` is then
  `{:any, features}`, a `t:gate/0` as `gate/1` reads it; `on?/1` and `visible?/2` answer
  for either form.

  A page of the Instance level names its feature with `instance:`,
  `use ApiaryWeb.Features, instance: :security`, or `instance: [any: [...]]`. Such a page
  has no organisation: the scope it is opened in carries the organisation the
  person opened last, whose `hidden` says nothing of the instance. Its gate asks the
  instance, `on?/1`, whoever opens it, and so does `page_shown?/2` once the page is open;
  whether the person may open the page is the page's to answer. `__feature__/0` is the
  feature, or `{:any, features}`, as without `instance:`, and `instance?/1` says the page
  is one of the Instance level.

  The features are the core's and the edition's (`Apiary.Features.all/0`), and the
  edition's are known only once it runs: whether a page names a feature there is is
  checked at boot, over the routes of the router the instance serves (`boot!/0`), not when
  the page compiles. What `use` is given is checked when the page compiles: a feature's
  name, or `any:` and two or more names, each once.
  """

  @behaviour Plug

  alias Apiary.Features

  defmodule NotFound do
    @moduledoc "Raised where a feature is off, and rendered as the 404 of a path that does not exist."
    defexception message: "not found", plug_status: 404
  end

  @typedoc """
  What a page names with `use ApiaryWeb.Features`: a feature, or `{:any, features}` for
  a page that is there when at least one of them is.
  """
  @type gate :: Features.feature() | {:any, [Features.feature(), ...]}

  defmacro __using__(opts) do
    {hook, named} = hook!(opts)

    # Which gate the caller can take is known from its imports, which are lexical and so
    # settled when this expands: a LiveView imports `on_mount/1`, a controller `plug/2`.
    gate =
      cond do
        Macro.Env.lookup_import(__CALLER__, {:on_mount, 1}) != [] ->
          quote do: on_mount({ApiaryWeb.Features, unquote(hook)})

        Macro.Env.lookup_import(__CALLER__, {:plug, 2}) != [] ->
          quote do: plug(ApiaryWeb.Features, unquote(hook))

        true ->
          raise ArgumentError, "use ApiaryWeb.Features belongs in a LiveView or a controller"
      end

    instance? = match?({:instance, _gate}, hook)

    quote do
      unquote(gate)

      @doc false
      def __feature__, do: unquote(named)

      @doc false
      def __instance_feature__?, do: unquote(instance?)
    end
  end

  # What the gate asks, `{:instance, gate}` for a page of the Instance level, and the gate
  # `use` is given.
  defp hook!(instance: opts) do
    named = gate!(opts)
    {{:instance, named}, named}
  end

  defp hook!(opts) do
    named = gate!(opts)
    {named, named}
  end

  # The gate `use` is given, or an `ArgumentError`: a feature's name, or `any:` and two or
  # more names, each once. Whether each names a feature there is is `boot!/0`'s to check.
  defp gate!(any: features) do
    unless is_list(features) and length(features) >= 2 and Enum.all?(features, &name?/1) and
             Enum.uniq(features) == features do
      raise ArgumentError,
            "use ApiaryWeb.Features, any: takes two or more names of features, each once, " <>
              "got: #{inspect(features)}"
    end

    {:any, features}
  end

  defp gate!(feature) do
    unless name?(feature) do
      raise ArgumentError,
            "use ApiaryWeb.Features takes the name of a feature, got: #{inspect(feature)}"
    end

    feature
  end

  defp name?(feature), do: is_atom(feature) and not is_nil(feature)

  @doc """
  gate/1 is what `module` names with `use ApiaryWeb.Features` (`t:gate/0`), or nil for a
  module that names no feature: a page every instance has, or no page.
  """
  @spec gate(module) :: gate | nil
  def gate(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__feature__, 0),
      do: module.__feature__()
  end

  @doc """
  instance?/1 is whether `module` is a page of the Instance level, which names its feature
  with `instance:`: its gate asks the instance, `on?/1`, whoever opens it. False for a
  module that names its feature without `instance:`, and for one that names none.
  """
  @spec instance?(module) :: boolean
  def instance?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__instance_feature__?, 0) and
      module.__instance_feature__?()
  end

  @doc """
  page_shown?/2 is whether the page of the LiveView or controller `module` is still there
  for `scope`, as its gate answers: true for a module that names no feature; for a page of
  the Instance level (`instance?/1`), whether the instance has the feature, whatever
  organisation `scope` carries (`on?/1`); for any other, whether it is shown where `scope`
  is (`visible?/2`).
  """
  @spec page_shown?(module, Apiary.Accounts.Scope.t() | nil) :: boolean
  def page_shown?(module, scope) when is_atom(module) do
    case gate(module) do
      nil -> true
      gate -> if instance?(module), do: on?(gate), else: visible?(scope, gate)
    end
  end

  @doc "features/1 is the features `gate` names, in the order it names them."
  @spec features(gate) :: [Features.feature()]
  def features({:any, features}) when is_list(features), do: features
  def features(feature) when is_atom(feature), do: [feature]

  @doc """
  on?/1 is whether the instance has the feature `gate` names, or one of the features
  (`Apiary.Features.on?/1`).
  """
  @spec on?(gate) :: boolean
  def on?(gate), do: Enum.any?(features(gate), &Features.on?/1)

  @doc """
  visible?/2 is whether the feature `gate` names, or one of the features, is shown where
  `scope` is (`Apiary.Features.visible?/2`).
  """
  @spec visible?(Apiary.Accounts.Scope.t() | Apiary.AccessKeys.AccessKey.t() | nil, gate) ::
          boolean
  def visible?(scope, gate), do: Enum.any?(features(gate), &Features.visible?(scope, &1))

  @doc """
  boot!/0 checks that every route of the router the instance serves, whose LiveView or
  controller declares a feature, names one of `Apiary.Features.all/0`. Called at boot;
  raises on one that does not, so the instance does not start.
  """
  @spec boot!() :: :ok
  def boot!, do: check_routes!(ApiaryWeb.Edition.router())

  @doc """
  check_routes!/1 is `boot!/0`'s check over the routes of `router`: `:ok`, or an
  `ArgumentError` that names the first module that names a feature, alone or with `any:`,
  that is none of `Apiary.Features.all/0`.
  """
  @spec check_routes!(module) :: :ok
  def check_routes!(router) when is_atom(router) do
    all = Features.all()

    unknown =
      for route <- Phoenix.Router.routes(router),
          module = route_module(route),
          gate = gate(module),
          Enum.any?(features(gate), &(&1 not in all)),
          uniq: true,
          do: {module, gate}

    case unknown do
      [] ->
        :ok

      [{module, feature} | _] when is_atom(feature) ->
        raise ArgumentError,
              "#{inspect(module)} uses ApiaryWeb.Features with #{inspect(feature)}, " <>
                "which is not one of #{inspect(all)}"

      [{module, {:any, features}} | _] ->
        raise ArgumentError,
              "#{inspect(module)} uses ApiaryWeb.Features with any: #{inspect(features)}, " <>
                "and #{Enum.map_join(features -- all, ", ", &inspect/1)} is not one of " <>
                inspect(all)
    end
  end

  defp route_module(%{metadata: %{phoenix_live_view: {live_view, _action, _opts, _extra}}}),
    do: live_view

  defp route_module(%{plug: plug}), do: plug

  @doc false
  # A page of the Instance level asks the instance, whoever opens it.
  def on_mount({:instance, gate}, _params, _session, socket) do
    if on?(gate), do: {:cont, socket}, else: raise(NotFound)
  end

  def on_mount(gate, _params, _session, socket) do
    if visible?(socket.assigns[:current_scope], gate) do
      {:cont, socket}
    else
      raise NotFound
    end
  end

  @impl Plug
  def init(feature) when is_atom(feature), do: feature
  def init({:any, features} = gate) when is_list(features), do: gate
  def init({:instance, gate}), do: {:instance, init(gate)}

  @impl Plug
  def call(conn, {:instance, gate}) do
    if on?(gate), do: conn, else: absent(conn)
  end

  def call(conn, gate) do
    if shown?(conn, gate), do: conn, else: absent(conn)
  end

  # A person's scope asks what the person is shown; a signed request of the server contract,
  # which carries an access key and no person's scope, asks the instance.
  defp shown?(%{assigns: %{current_scope: %Apiary.Accounts.Scope{} = scope}}, gate),
    do: visible?(scope, gate)

  defp shown?(_conn, gate), do: on?(gate)

  # For a feature the instance has and a person is not shown, and for a signed request
  # of the server contract to a feature the instance does not have:
  # `ApiaryWeb.Features.Routes` has already answered for the instance, before any pipeline,
  # but for that signed request, which it lets through to be verified; the answer to that
  # one is signed as it is sent (`ApiaryWeb.Contract.SignedAnswer`). The pipeline has run
  # by now, so this can only come close to an unknown path: its body and type, not the
  # rendering in the format the pipeline chose, which raising would give.
  defp absent(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(404, ApiaryWeb.ErrorHTML.render("404.html", %{}))
    |> Plug.Conn.halt()
  end
end
