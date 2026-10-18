defmodule ApiaryWeb.ActivityNodeClearInstanceTest do
  # The Change of `node.clear_instance`: the instance by the id the entry recorded, a
  # text Forager sent, shown as a page shows one.
  use ExUnit.Case, async: true

  alias ApiaryWeb.Activity.Describer.Core

  test "names the instance by its id cleaned, and marks one with nothing left to show" do
    details = %{"instance_id" => "i\u202E_1\u200B", "runs" => 2}

    assert [[{:m, "i_1"}], _runs] =
             Core.change(:"node.clear_instance", nil, nil, details)

    assert [[{:m, "\uFFFD"}], _runs] =
             Core.change(:"node.clear_instance", nil, nil, %{details | "instance_id" => " "})
  end
end
