defmodule ApiaryWeb.ActivityModelProviderTest do
  # The Activity lines of a model provider's `connection.write` entries: each sentence by
  # the change in its details, and the change it shows, the host, the key's value ID or
  # the model ID, never a key.
  use Apiary.DataCase, async: true

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer

  defp entry(change, details \\ %{}),
    do: %Entry{
      action: "connection.write",
      actor_kind: :user,
      details:
        Map.merge(
          %{"change" => change, "connection_id" => "con_0123456789abcdef", "name" => "Models"},
          details
        ),
      subject_kind: "connection",
      subject_id: Ecto.UUID.generate()
    }

  defp shown(entry),
    do: Enum.find_value(Describer.describers(), & &1.sentence(:"connection.write", entry, %{}))

  defp changed(before, after_, details),
    do:
      Enum.find_value(
        Describer.describers(),
        & &1.change(:"connection.write", before, after_, details)
      )

  test "each change of a provider has its sentence" do
    for {change, sentence} <- [
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
      assert shown(entry(change)) == sentence
    end
  end

  test "the change shows the host, the value ID or the model ID" do
    assert changed(
             %{"host" => "a.example.com"},
             %{"host" => "b.example.com"},
             entry("provider_address_changed").details
           ) == Describer.from_to("a.example.com", "b.example.com")

    assert changed(
             %{"default_value_id" => "main"},
             %{"default_value_id" => "spare"},
             entry("provider_default_key_changed").details
           ) == Describer.from_to("main", "spare")

    assert changed(
             %{"default_model_id" => "m1"},
             %{"default_model_id" => "m2"},
             entry("provider_default_model_changed").details
           ) == Describer.from_to("m1", "m2")

    for change <- ~w(provider_model_added provider_model_changed provider_model_removed) do
      assert changed(%{}, %{}, entry(change, %{"model_id" => "acme/m1"}).details) ==
               [{:m, "acme/m1"}]
    end

    assert changed(
             %{"value_id" => "main"},
             %{"value_id" => "first"},
             entry("provider_keys_changed").details
           ) == Describer.from_to("main", "first")

    assert changed(nil, nil, entry("provider_keys_changed", %{"value_id" => "spare"}).details) ==
             [{:m, "spare"}]

    assert changed(%{}, %{}, entry("provider_created").details) == nil
  end
end
