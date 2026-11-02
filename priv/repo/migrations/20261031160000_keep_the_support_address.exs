defmodule Apiary.Repo.Migrations.KeepTheSupportAddress do
  use Ecto.Migration

  # `support_address`: where "Contact support" leads on the pages people in an
  # organisation see (`Apiary.SupportAddress`), an https address or an email address that
  # an instance admin saved in Instance settings › General; NULL for none, and then
  # "Contact support" shows as plain text. `SUPPORT_ADDRESS` in the server's environment
  # wins over it.
  def change do
    alter table(:instance_settings) do
      add :support_address, :text
    end

    create constraint(:instance_settings, :instance_settings_support_address_length,
             check: "char_length(support_address) BETWEEN 1 AND 2048"
           )
  end
end
