defmodule Apiary.Repo.Migrations.HoldAGatewaySAddressToTheContracts do
  use Ecto.Migration

  # A gateway's address is the contracts' `gateway_url` (`Apiary.Contract.GatewayUrl`):
  # `https://`, a host of DNS labels or an IPv6 address in brackets, an optional port, 1
  # to 65535, and nothing after them, at most 300 characters. The check before allowed a
  # trailing dot and 2048 characters, and refused a last label of digits alone.
  # `nodes_url_check` is re-created to say so, NOT VALID, so the change scans no row under
  # a lock that blocks writes to `nodes`; the next migration validates it, and stops
  # while a gateway's address is outside it.
  @label "[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
  @name "#{@label}(?:\\.#{@label})*"
  @dec_octet "(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
  @ipv4 "#{@dec_octet}\\.#{@dec_octet}\\.#{@dec_octet}\\.#{@dec_octet}"
  @h16 "[0-9A-Fa-f]{1,4}"
  @ls32 "(?:#{@h16}:#{@h16}|#{@ipv4})"
  @ipv6 Enum.join(
          [
            "(?:#{@h16}:){6}#{@ls32}",
            "::(?:#{@h16}:){5}#{@ls32}",
            "(?:#{@h16})?::(?:#{@h16}:){4}#{@ls32}",
            "(?:(?:#{@h16}:){0,1}#{@h16})?::(?:#{@h16}:){3}#{@ls32}",
            "(?:(?:#{@h16}:){0,2}#{@h16})?::(?:#{@h16}:){2}#{@ls32}",
            "(?:(?:#{@h16}:){0,3}#{@h16})?::#{@h16}:#{@ls32}",
            "(?:(?:#{@h16}:){0,4}#{@h16})?::#{@ls32}",
            "(?:(?:#{@h16}:){0,5}#{@h16})?::#{@h16}",
            "(?:(?:#{@h16}:){0,6}#{@h16})?::"
          ],
          "|"
        )
  @port "(?::(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?"
  @url "^https://(?:#{@name}|\\[(?:#{@ipv6})\\])#{@port}$"

  # The check before, as `20261011160700` made it, for `down/0`.
  @before_label "[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
  @before_name "(?=[A-Za-z0-9.-]{1,253}\\.?(:|$))(#{@before_label}\\.)*(?![0-9]+\\.?(:|$))#{@before_label}\\.?"

  @before_octet "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
  @before_ipv4 "#{@before_octet}\\.#{@before_octet}\\.#{@before_octet}\\.#{@before_octet}"

  @before_h "[0-9A-Fa-f]{1,4}"
  @before_ipv6 Enum.join(
                 [
                   "(#{@before_h}:){7}#{@before_h}",
                   "::((#{@before_h}:){0,6}#{@before_h})?",
                   "#{@before_h}::((#{@before_h}:){0,5}#{@before_h})?",
                   "#{@before_h}(:#{@before_h}){1}::((#{@before_h}:){0,4}#{@before_h})?",
                   "#{@before_h}(:#{@before_h}){2}::((#{@before_h}:){0,3}#{@before_h})?",
                   "#{@before_h}(:#{@before_h}){3}::((#{@before_h}:){0,2}#{@before_h})?",
                   "#{@before_h}(:#{@before_h}){4}::((#{@before_h}:){0,1}#{@before_h})?",
                   "#{@before_h}(:#{@before_h}){5}::(#{@before_h})?",
                   "#{@before_h}(:#{@before_h}){6}::",
                   "(#{@before_h}:){6}#{@before_ipv4}",
                   "::(#{@before_h}:){0,5}#{@before_ipv4}",
                   "#{@before_h}::(#{@before_h}:){0,4}#{@before_ipv4}",
                   "#{@before_h}(:#{@before_h}){1}::(#{@before_h}:){0,3}#{@before_ipv4}",
                   "#{@before_h}(:#{@before_h}){2}::(#{@before_h}:){0,2}#{@before_ipv4}",
                   "#{@before_h}(:#{@before_h}){3}::(#{@before_h}:){0,1}#{@before_ipv4}",
                   "#{@before_h}(:#{@before_h}){4}::#{@before_ipv4}"
                 ],
                 "|"
               )

  @before_port "([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])"

  @before_url "^https://(#{@before_name}|#{@before_ipv4}|\\[(#{@before_ipv6})\\])(:#{@before_port})?$"

  def up do
    drop constraint(:nodes, :nodes_url_check)

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_url_check CHECK (
      (kind = 'gateway') = (url IS NOT NULL) AND
      (url IS NULL OR (char_length(url) <= 300 AND url ~ '#{@url}'))
    ) NOT VALID
    """
  end

  def down do
    drop constraint(:nodes, :nodes_url_check)

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_url_check CHECK (
      (kind = 'gateway') = (url IS NOT NULL) AND
      (url IS NULL OR (char_length(url) <= 2048 AND url ~ '#{@before_url}'))
    ) NOT VALID
    """
  end
end
