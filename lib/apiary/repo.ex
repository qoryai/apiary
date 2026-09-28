defmodule Apiary.Repo do
  use Ecto.Repo,
    otp_app: :apiary,
    adapter: Ecto.Adapters.Postgres
end
