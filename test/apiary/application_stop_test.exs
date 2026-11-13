defmodule Apiary.ApplicationStopTest do
  # The endpoint's place in the application's tree: the deadline after it cuts what is
  # still open when the endpoint's stop has lasted 20 s (`ApiaryWeb.Endpoint.stop_timeout/1`).
  use ExUnit.Case, async: true

  test "the deadline comes after the endpoint, with the 20 s" do
    assert {:ok, %{start: {ApiaryWeb.EndpointDeadline, :start_link, [opts]}}} =
             :supervisor.get_childspec(Apiary.Supervisor, ApiaryWeb.EndpointDeadline)

    assert opts == [endpoint: ApiaryWeb.Endpoint, timeout: 20_000]

    # Last, so a stop reaches it before the endpoint.
    assert [{ApiaryWeb.EndpointDeadline, _, _, _}, {ApiaryWeb.Endpoint, _, _, _} | _] =
             Supervisor.which_children(Apiary.Supervisor)
  end
end
