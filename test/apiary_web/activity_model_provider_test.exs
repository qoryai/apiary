defmodule ApiaryWeb.ActivityModelProviderTest do
  # The Activity lines of a model provider's `provider.write` entries, and of the
  # `connection.write` entries stored before that action was split from it: each sentence
  # by the change in its details, and the change it shows, the host, the key's value ID or
  # the model ID, never a key.
  use Apiary.DataCase, async: true

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer

  @actions [:"provider.write", :"connection.write"]

  defp entry(action, change, details \\ %{}),
    do: %Entry{
      action: Atom.to_string(action),
      actor_kind: :user,
      details:
        Map.merge(
          %{"change" => change, "connection_id" => "con_0123456789abcdef", "name" => "Models"},
          details
        ),
      subject_kind: "connection",
      subject_id: Ecto.UUID.generate()
    }

  defp shown(action, entry),
    do: Enum.find_value(Describer.describers(), & &1.sentence(action, entry, %{}))

  defp changed(action, before, after_, details),
    do:
      Enum.find_value(
        Describer.describers(),
        & &1.change(action, before, after_, details)
      )

  test "each change of a provider has its sentence" do
    for action <- @actions,
        {change, sentence} <- [
          {"provider_created", "Added a model provider"},
          {"provider_deleted", "Removed a model provider"},
          {"provider_address_changed", "Changed a model provider's address"},
          {"provider_default_key_changed", "Changed a model provider's default key"},
          {"provider_keys_changed", "Changed a model provider's keys"},
          {"provider_model_added", "Added a model to a model provider"},
          {"provider_model_changed", "Changed a model of a model provider"},
          {"provider_model_removed", "Removed a model from a model provider"},
          {"provider_default_model_changed", "Changed a model provider's default model"}
        ] do
      assert shown(action, entry(action, change)) == sentence
    end
  end

  test "the change shows the host, the value ID or the model ID" do
    for action <- @actions do
      details = &entry(action, &1, &2).details
      changed = &changed(action, &1, &2, &3)

      assert changed.(
               %{"host" => "a.example.com"},
               %{"host" => "b.example.com"},
               details.("provider_address_changed", %{})
             ) == Describer.from_to("a.example.com", "b.example.com")

      assert changed.(
               %{"default_value_id" => "main"},
               %{"default_value_id" => "spare"},
               details.("provider_default_key_changed", %{})
             ) == Describer.from_to("main", "spare")

      assert changed.(
               %{"default_model_id" => "m1"},
               %{"default_model_id" => "m2"},
               details.("provider_default_model_changed", %{})
             ) == Describer.from_to("m1", "m2")

      for change <- ~w(provider_model_added provider_model_changed provider_model_removed) do
        assert changed.(%{}, %{}, details.(change, %{"model_id" => "acme/m1"})) ==
                 [{:m, "acme/m1"}]
      end

      assert changed.(
               %{"value_id" => "main"},
               %{"value_id" => "first"},
               details.("provider_keys_changed", %{})
             ) == Describer.from_to("main", "first")

      assert changed.(nil, nil, details.("provider_keys_changed", %{"value_id" => "spare"})) ==
               [{:m, "spare"}]

      assert changed.(%{}, %{}, details.("provider_created", %{})) == nil
    end
  end
end
