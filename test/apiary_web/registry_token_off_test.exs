defmodule ApiaryWeb.RegistryTokenOffTest do
  # Without the `registry` feature, the token route is a path the instance does not
  # serve, for every method. Not async: `without_registry` changes the whole node's
  # features.
  use ApiaryWeb.ConnCase, async: false

  setup {Apiary.DataCase, :without_registry}

  test "answers 404 for every method" do
    refute Apiary.Features.on?(:registry)

    for method <- [:get, :post, :put, :delete] do
      conn =
        build_conn()
        |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("run_x", "secret"))
        |> dispatch(@endpoint, method, "/registry/token?service=registry.test.example", nil)

      assert conn.status == 404, inspect(method)
      refute conn.resp_body =~ "registry"
    end
  end
end
