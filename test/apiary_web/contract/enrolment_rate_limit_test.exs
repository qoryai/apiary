defmodule ApiaryWeb.Contract.EnrolmentRateLimitTest do
  # The limit comes from the application environment, which every test shares.
  use ApiaryWeb.ConnCase, async: false

  alias ApiaryWeb.Contract.EnrolmentController

  setup do
    config = Application.get_env(:apiary, EnrolmentController)
    Application.put_env(:apiary, EnrolmentController, rate: 1, burst: 2)
    on_exit(fn -> Application.put_env(:apiary, EnrolmentController, config) end)
  end

  defp enrol(address) do
    build_conn()
    |> Map.put(:remote_ip, address)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-qory-contract-version", "1")
    |> post("/.well-known/qory-enrolment", "{}")
  end

  test "an address over its limit is 429 unsigned, with Retry-After, before the body is read; another address is not" do
    address = {192, 0, 2, 17}

    for _ <- 1..2, do: assert(enrol(address).status == 400)

    conn = enrol(address)
    assert conn.status == 429
    assert Jason.decode!(conn.resp_body) == %{"error" => "rate_limited"}
    assert get_resp_header(conn, "retry-after") == ["1"]
    assert get_resp_header(conn, "x-qory-signature-ed25519") == []

    assert enrol({192, 0, 2, 18}).status == 400
  end
end
