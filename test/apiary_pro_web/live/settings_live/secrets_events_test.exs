defmodule ApiaryProWeb.SettingsLive.SecretsEventsTest do
  # An event the organisation's Secrets page never sends, with a plaintext value in it, is
  # refused in silence: the page's process stays up, so no crash report prints the event,
  # no log line holds the value, and the organisation's secrets stay as they were. A
  # deletion's confirmation reads no parameters: given any, it deletes, and logs no value.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Apiary.{Features, Repo, Secrets}
  alias Apiary.Secrets.{Secret, Value}

  @moduletag with_features: Features.all()
  @moduletag needs: :organisation_variables

  # What a client might send as a secret's value: no log line may hold it.
  @marker "plaintext-marker-7c2a"

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, one} =
      Secrets.create_organisation_secret(scope, %{"name" => "FORGE_TOKEN", "value" => @marker})

    {:ok, several} =
      Secrets.create_organisation_secret(scope, %{
        "name" => "APP_KEYS",
        "values" => %{
          "0" => %{"value_id" => "main-app", "value" => @marker},
          "1" => %{"value_id" => "bot-app", "value" => @marker}
        }
      })

    %{one: one.public_id, several: several.public_id}
  end

  # Each page of the section but the deletions' confirmations, with the events it answers
  # in its act; `:one` and `:several` stand for the ids of the setup's. On the list, with
  # no confirmation open, a deletion's event deletes nothing.
  @pages [
    {"", :all},
    {"/new", ~w(create_secret)},
    {"/:one/edit", ~w(update_secret)},
    {"/:one/add-value", ~w(add_value)},
    {"/:one/change-value", ~w(set_value)},
    {"/:several/values/main-app/change", ~w(set_value)},
    {"/:several/values/main-app/rename", ~w(rename_value)}
  ]

  # The deletions' confirmations, with the event each answers: each payload is sent to a
  # confirmation opened for it, on a secret made for it.
  @deletions [
    {"/:secret/values/main-app/delete", "delete_value"},
    {"/:secret/delete", "delete_secret"}
  ]

  # Each event the page names, with the key its form sends its fields under and those
  # fields; `nil` for an event whose parameters are the fields themselves.
  defp shapes do
    %{
      "find" => {nil, ~w(q)},
      "create_secret" => {"secret", ~w(name note value values_kind values)},
      "update_secret" => {"secret", ~w(name note)},
      "add_value" => {"secret_value", ~w(value_id value first_value_id)},
      "set_value" => {"secret_value", ~w(value)},
      "rename_value" => {"secret_value", ~w(value_id)},
      "delete_value" => {nil, []},
      "delete_secret" => {nil, []},
      "no_such_event" => {"secret", ~w(name value)}
    }
  end

  # The parameters of an event whose handler reads none: every shape, each holding the
  # marker.
  defp any_parameters do
    m = @marker

    [m, nil, %{}, %{"value" => m}, %{"id" => [m]}, %{"secret" => %{"value" => [m]}}] ++
      wrong()
  end

  # What stands where a string is expected: each holds the marker.
  defp wrong do
    m = @marker
    [[m], [[m]], %{"0" => m}, %{"x" => %{"y" => m}}, [%{"x" => m}], 42, -1, 1.5, true]
  end

  # The payloads of one event no form sends: wrong at the top, wrong under the form's key,
  # each field wrong in turn with the others holding the marker, and several values that
  # are not a map of rows, or rows whose fields are not text, which the changeset refuses.
  defp crafted(event) when event in ~w(delete_value delete_secret), do: any_parameters()

  defp crafted(event) do
    m = @marker
    {wrapper, fields} = Map.fetch!(shapes(), event)
    full = Map.new(fields, &{&1, m})
    wrap = fn fields -> if wrapper, do: %{wrapper => fields, "value" => m}, else: fields end

    top =
      if wrapper || fields != [],
        do: [m, 42, nil, true, [m], [%{"value" => m}], %{"value" => m}, %{"other" => m}],
        else: []

    under = if wrapper, do: for(w <- [m | wrong()], do: %{wrapper => w}), else: []

    per_field =
      for field <- fields, w <- wrong(), do: wrap.(Map.put(full, field, w))

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

    top ++ under ++ per_field ++ several
  end

  # The payloads a form might send, strings each, or a field missing, or one more: one of
  # them may be saved.
  defp strings(event) do
    m = @marker
    {wrapper, fields} = Map.fetch!(shapes(), event)
    full = Map.new(fields, &{&1, m})
    wrap = fn fields -> if wrapper, do: %{wrapper => fields}, else: fields end

    for(field <- fields, do: wrap.(Map.delete(full, field))) ++
      [wrap.(full), wrap.(Map.put(full, "extra", m))] ++
      for field <- fields, do: wrap.(Map.put(full, field, m <> <<0>>))
  end

  defp page_path(scope, rest, ids) do
    rest =
      Enum.reduce(ids, rest, fn {name, id}, rest ->
        String.replace(rest, ":#{name}", to_string(id))
      end)

    "/#{scope.organisation.slug}/settings/secrets#{rest}"
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

  # Each event of the page, sent each payload as each way `payloads` names that it can be
  # sent: the events that took the page down. One page takes them all, as one client
  # would send them, and a page is opened again only after one went down.
  defp sweep(conn, path, events, payloads) do
    for event <- events,
        {payload, sent_as} <- payloads.(event),
        type <- types(payload),
        type in sent_as,
        reduce: {nil, []} do
      {lv, downs} ->
        lv = lv || mount(conn, path)

        case push(lv, type, event, payload) do
          :ok -> {lv, downs}
          :down -> {nil, [{event, type} | downs]}
        end
    end
    |> elem(1)
    |> Enum.reverse()
  end

  defp mount(conn, path) do
    {:ok, lv, _html} = live(conn, path)
    lv
  end

  # The organisation's secrets as stored: each one's name and note, and its values.
  defp stored(scope) do
    Repo.all(
      from s in Secret,
        join: v in Value,
        on: v.secret_id == s.id,
        where: s.organisation_id == ^scope.organisation.id and is_nil(s.workspace_id),
        order_by: [s.name, v.value_id],
        select: {s.name, s.note, s.updated_at, v.value_id, v.ciphertext, v.updated_at}
    )
  end

  for {rest, events} <- @pages do
    @rest rest
    @events events

    test "an event no form sends on #{if rest == "", do: "the list", else: rest} leaves " <>
           "the page up, nothing changed, and no value in a log line",
         %{conn: conn, scope: scope} = context do
      Process.flag(:trap_exit, true)
      path = page_path(scope, @rest, Map.take(context, [:one, :several]))
      events = if @events == :all, do: Map.keys(shapes()), else: @events
      before = stored(scope)

      hooks = fn event -> for payload <- crafted(event), do: {payload, ["hook"]} end
      {downs, log} = with_log([level: :error], fn -> sweep(conn, path, events, hooks) end)

      refute log =~ @marker
      assert downs == []
      assert stored(scope) == before

      # As a form encodes them, a number or a boolean arrives as text, which a form may
      # send and the page may save; and strings, as a form sends them. The page answers,
      # and logs no value either.
      forms = fn event ->
        for(payload <- crafted(event), do: {payload, ["form"]}) ++
          for payload <- strings(event), do: {payload, ["hook", "form"]}
      end

      {downs, log} = with_log([level: :error], fn -> sweep(conn, path, events, forms) end)

      refute log =~ @marker
      assert downs == []
    end
  end

  # A secret of two values, whose confirmation one payload is sent to.
  defp deletable(scope) do
    {:ok, secret} =
      Secrets.create_organisation_secret(scope, %{
        "name" => "KEY_#{System.unique_integer([:positive])}",
        "values" => %{
          "0" => %{"value_id" => "main-app", "value" => @marker},
          "1" => %{"value_id" => "bot-app", "value" => @marker}
        }
      })

    secret
  end

  for {rest, event} <- @deletions do
    @rest rest
    @event event

    test "#{event} on #{rest}, given parameters of every shape, deletes, leaves the page " <>
           "up, and logs no value",
         %{conn: conn, scope: scope} do
      Process.flag(:trap_exit, true)

      {results, log} =
        with_log([level: :error], fn ->
          for payload <- any_parameters(), type <- types(payload) do
            secret = deletable(scope)
            lv = mount(conn, page_path(scope, @rest, secret: secret.public_id))
            {push(lv, type, @event, payload), Process.alive?(lv.pid)}
          end
        end)

      refute log =~ @marker
      assert Enum.all?(results, &(&1 == {:ok, true}))

      # The handler reads no parameters: each confirmation deleted what it asked about,
      # the value or the secret, and every secret made here is down to one value or gone.
      left = for {name, _note, _at, value_id, _c, _u} <- stored(scope), do: {name, value_id}
      made = for {name, _value_id} <- left, String.starts_with?(name, "KEY_"), do: name

      if @event == "delete_value",
        do: assert(Enum.frequencies(made) |> Map.values() == List.duplicate(1, length(results))),
        else: assert(made == [])
    end
  end
end
