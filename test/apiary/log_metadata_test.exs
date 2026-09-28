defmodule Apiary.LogMetadataTest do
  use ExUnit.Case, async: true

  alias Apiary.LogMetadata

  doctest Apiary.LogMetadata

  test "metadata/2 passes only UUIDs, in their canonical form" do
    id = Ecto.UUID.generate()

    assert LogMetadata.metadata(String.upcase(id), nil) == [organisation_id: id]
    assert LogMetadata.metadata(id, id) == [organisation_id: id, workspace_id: id]
    assert LogMetadata.metadata(42, "Acme Ltd") == []
    assert LogMetadata.metadata(nil, nil, id) == [user_id: id]
    assert LogMetadata.metadata(nil, nil, "person@example.com") == []
  end

  test "carry/1 runs a function in another process under this one's ids" do
    LogMetadata.put_ids(Ecto.UUID.generate(), nil, Ecto.UUID.generate())
    ids = LogMetadata.get()

    assert ids |> Map.values() |> Enum.count(&is_nil/1) == 1
    assert Task.await(Task.async(LogMetadata.carry(&LogMetadata.get/0))) == ids
  end
end
