defmodule ApiaryWeb.SecretLive.EventsTest do
  # An event the page's forms never send, with a plaintext value in it, is refused in
  # silence: the page's process stays up, so no crash report prints the event, and no log
  # line holds the value.
  use ApiaryWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Apiary.{Secrets, Variables}

  @moduletag needs: :secrets

  # What a client might send as a secret's value: no log line may hold it.
  @marker "plaintext-marker-5e1c"

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, one} = Secrets.create_secret(scope, %{name: "FORGE_TOKEN", value: @marker})

    {:ok, several} =
      Secrets.create_secret(scope, %{
        name: "APP_KEYS",
        values: [
          %{value_id: "main-app", value: @marker},
          %{value_id: "bot-app", value: @marker}
        ]
      })

    {:ok, variable} =
      Variables.create_variable(scope, :workspace, %{name: "NODE_ENV", value: "production"})

    {:ok, locked} =
      Variables.create_variable(scope, :workspace, %{
        name: "NPM_REGISTRY",
        value: "https://registry.example.com",
        locked: true
      })

    %{one: one.public_id, several: several.public_id, variable: variable.id, locked: locked.id}
  end

  # Each page of the section, with the events it answers in its act; `:one`, `:several`,
  # `:variable` and `:locked` stand for the ids of the setup's.
  @pages [
    {"/settings/secrets", :all},
    {"/settings/secrets/new", ~w(create_secret)},
    {"/settings/secrets/:one/edit", ~w(update_secret)},
    {"/settings/secrets/:one/add-value", ~w(add_value)},
    {"/settings/secrets/:one/change-value", ~w(set_value)},
    {"/settings/secrets/:several/values/main-app/change", ~w(set_value)},
    {"/settings/secrets/:several/values/main-app/rename", ~w(rename_value)},
    {"/settings/secrets/:several/values/main-app/delete", ~w(delete_value)},
    {"/settings/secrets/:one/delete", ~w(delete_secret)},
    {"/settings/variables", ~w(find lock_variable unlock_variable delete_variable)},
    {"/settings/variables/new", ~w(validate_variable create_variable)},
    {"/settings/variables/:variable/change", ~w(change_variable)},
    {"/settings/variables/:variable/lock", ~w(lock_variable)},
    {"/settings/variables/:locked/unlock", ~w(unlock_variable)},
    {"/settings/variables/:variable/delete", ~w(delete_variable)},
    {"/settings/variables/:variable/targets", ~w(find_target)}
  ]

  # Each event the page names, with the key its form sends its fields under and those
  # fields; `nil` for an event whose parameters are the fields themselves.
  defp shapes do
    %{
      "find" => {nil, ~w(q)},
      "find_target" => {nil, ~w(q)},
      "create_secret" => {"secret", ~w(name note value values_kind values)},
      "update_secret" => {"secret", ~w(name note)},
      "add_value" => {"secret_value", ~w(value_id value first_value_id)},
      "set_value" => {"secret_value", ~w(value)},
      "rename_value" => {"secret_value", ~w(value_id)},
      "delete_value" => {nil, []},
      "delete_secret" => {nil, []},
      "validate_variable" => {"variable", ~w(name value locked)},
      "create_variable" => {"variable", ~w(name value locked)},
      "change_variable" => {"variable", ~w(value)},
      "lock_variable" => {nil, ~w(id)},
      "unlock_variable" => {nil, ~w(id)},
      "delete_variable" => {nil, ~w(id)},
      "no_such_event" => {"secret", ~w(name value)}
    }
  end

  # What stands where a string is expected: each holds the marker.
  defp wrong do
    m = @marker
    [[m], [[m]], %{"0" => m}, %{"x" => %{"y" => m}}, [%{"x" => m}], 42, -1, 1.5, true]
  end

  # The payloads of one event: wrong at the top, wrong under the form's key, each field
  # wrong in turn with the others holding the marker, each field missing, a key no form
  # sends, the marker under each key the form uses, and the shapes of several values.
  defp payloads(event) do
    m = @marker
    {wrapper, fields} = Map.fetch!(shapes(), event)
    full = Map.new(fields, &{&1, m})
    wrap = fn fields -> if wrapper, do: %{wrapper => fields, "value" => m}, else: fields end

    top = [m, 42, nil, true, [m], [%{"value" => m}], %{}, %{"value" => m}, %{"other" => m}]
    under = if wrapper, do: for(w <- [m | wrong()], do: %{wrapper => w}), else: []

    per_field =
      for field <- fields,
          payload <- [
            wrap.(Map.delete(full, field)) | for(w <- wrong(), do: wrap.(Map.put(full, field, w)))
          ],
          do: payload

    # Strings, as a form sends them, last: one of them may be saved.
    strings =
      [wrap.(full), wrap.(Map.put(full, "extra", m))] ++
        for field <- fields, do: wrap.(Map.put(full, field, m <> <<0>>))

    several =
      if "values" in fields do
        for values <- [
              m,
              [m],
              %{"0" => m},
              [%{"value_id" => "app", "value" => m}],
              %{"0" => %{"value_id" => [m], "value" => m}},
              %{"0" => %{"value_id" => "app", "value" => %{"x" => m}}},
              %{"0" => %{"value_id" => "app", "value" => [m]}},
              %{"0" => %{"value_id" => "app", "value" => 42}},
              %{"0" => %{"value_id" => %{"x" => m}, "value" => m}},
              %{"0" => %{"value" => m}},
              %{[m] => %{"value_id" => "app", "value" => m}}
            ],
            do: wrap.(Map.merge(full, %{"values_kind" => "several", "values" => values}))
      else
        []
      end

    top ++ under ++ per_field ++ several ++ strings
  end

  defp page_path(scope, rest, ids) do
    rest =
      Enum.reduce(ids, rest, fn {name, id}, rest ->
        String.replace(rest, ":#{name}", to_string(id))
      end)

    "/#{scope.organisation.slug}/#{scope.workspace.slug}#{rest}"
  end

  # The event as a client sends it on the page's channel: a hook's value as it comes, a
  # form's encoded as a form encodes it. The page's state, read after it, says it was
  # answered.
  defp push(lv, type, event, value) do
    {_ref, topic, _proxy} = lv.proxy
    value = if type == "form", do: Plug.Conn.Query.encode(value), else: value

    send(lv.pid, %Phoenix.Socket.Message{
      topic: topic,
      event: "event",
      ref: "events-test",
      payload: %{"type" => type, "event" => event, "value" => value}
    })

    :sys.get_state(lv.pid)
    :ok
  catch
    :exit, _down -> :down
  end

  # A form's encoding takes a map, and no map of more than one key inside a list.
  defp types(value) when is_map(value) do
    Plug.Conn.Query.encode(value)
    ["hook", "form"]
  rescue
    ArgumentError -> ["hook"]
  end

  defp types(_value), do: ["hook"]

  # Each event of the page, sent each payload: the events that took the page down.
  defp sweep(conn, path, events) do
    for event <- events, payload <- payloads(event), type <- types(payload), reduce: {nil, []} do
      {lv, downs} ->
        lv = lv || mount(conn, path)

        case push(lv, type, event, payload) do
          :ok -> {lv, downs}
          :down -> {nil, [{event, type, payload} | downs]}
        end
    end
    |> elem(1)
    |> Enum.reverse()
  end

  defp mount(conn, path) do
    {:ok, lv, _html} = live(conn, path)
    lv
  end

  for {rest, events} <- @pages do
    @rest rest
    @events events

    test "an event no form sends on #{rest} leaves the page up, and no value in a log line",
         %{conn: conn, scope: scope} = context do
      Process.flag(:trap_exit, true)
      ids = Map.take(context, [:one, :several, :variable, :locked])
      events = if @events == :all, do: Map.keys(shapes()), else: @events

      {downs, log} =
        with_log([level: :error], fn -> sweep(conn, page_path(scope, @rest, ids), events) end)

      refute log =~ @marker
      assert downs == []
    end
  end

  # The check above sees what a crash report prints: a process that fails on a term
  # holding the marker logs the marker.
  test "a crash report prints the arguments a process failed on" do
    Process.flag(:trap_exit, true)

    log =
      capture_log([level: :error], fn ->
        {:ok, pid} = Agent.start_link(fn -> nil end)
        ref = Process.monitor(pid)
        term = Process.get(:never_set, %{"value" => @marker})
        Agent.cast(pid, fn _state -> String.trim(term) end)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      end)

    assert log =~ @marker
  end
end
