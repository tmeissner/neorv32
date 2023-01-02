-- #################################################################################################
-- # << NEORV32 - Custom Functions Subsystem (CFS) >>                                              #
-- # ********************************************************************************************* #
-- # Intended for tightly-coupled, application-specific custom co-processors. This module provides #
-- # 32x 32-bit memory-mapped interface registers, one interrupt request signal and custom IO      #
-- # conduits for processor-external or chip-external interface.                                   #
-- #                                                                                               #
-- # NOTE: This is just an example/illustration template. Modify/replace this file to implement    #
-- #       your own custom design logic.                                                           #
-- # ********************************************************************************************* #
-- # BSD 3-Clause License                                                                          #
-- #                                                                                               #
-- # Copyright (c) 2022, Stephan Nolting. All rights reserved.                                     #
-- #                                                                                               #
-- # Redistribution and use in source and binary forms, with or without modification, are          #
-- # permitted provided that the following conditions are met:                                     #
-- #                                                                                               #
-- # 1. Redistributions of source code must retain the above copyright notice, this list of        #
-- #    conditions and the following disclaimer.                                                   #
-- #                                                                                               #
-- # 2. Redistributions in binary form must reproduce the above copyright notice, this list of     #
-- #    conditions and the following disclaimer in the documentation and/or other materials        #
-- #    provided with the distribution.                                                            #
-- #                                                                                               #
-- # 3. Neither the name of the copyright holder nor the names of its contributors may be used to  #
-- #    endorse or promote products derived from this software without specific prior written      #
-- #    permission.                                                                                #
-- #                                                                                               #
-- # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS   #
-- # OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF               #
-- # MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE    #
-- # COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,     #
-- # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE #
-- # GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED    #
-- # AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING     #
-- # NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED  #
-- # OF THE POSSIBILITY OF SUCH DAMAGE.                                                            #
-- # ********************************************************************************************* #
-- # The NEORV32 Processor - https://github.com/stnolting/neorv32              (c) Stephan Nolting #
-- #################################################################################################

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

entity neorv32_cfs_aes is
  generic (
    AES_CONFIG : std_ulogic_vector(31 downto 0) -- custom CFS configuration generic
  );
  port (
    -- host access --
    clk_i       : in  std_ulogic; -- global clock line
    rstn_i      : in  std_ulogic; -- global reset line, low-active, use as async
    priv_i      : in  std_ulogic; -- current CPU privilege mode
    addr_i      : in  std_ulogic_vector(31 downto 0); -- address
    rden_i      : in  std_ulogic; -- read enable
    wren_i      : in  std_ulogic; -- word write enable
    data_i      : in  std_ulogic_vector(31 downto 0); -- data in
    data_o      : out std_ulogic_vector(31 downto 0); -- data out
    ack_o       : out std_ulogic; -- transfer acknowledge
    err_o       : out std_ulogic; -- transfer error
    -- interrupt --
    irq_o       : out std_ulogic  -- interrupt request
  );
end neorv32_cfs_aes;

architecture neorv32_cfs_rtl of neorv32_cfs_aes is

  -- IO space: module base address --
  -- WARNING: Do not modify the CFS base address or the CFS' occupied address
  -- space as this might cause access collisions with other processor modules.
  constant hi_abb_c : natural := index_size_f(io_size_c)-1; -- high address boundary bit
  constant lo_abb_c : natural := index_size_f(aes_size_c); -- low address boundary bit

  -- access control --
  signal acc_en : std_ulogic; -- module access enable
  signal addr   : std_ulogic_vector(31 downto 0); -- access address
  signal wren   : std_ulogic; -- word write enable
  signal rden   : std_ulogic; -- read enable

  -- AES registers --
  signal aes_ctrl : std_logic_vector(31 downto 0);-- AES control register
  signal aes_key  : std_logic_vector(0 to 127);-- AES key register
  signal aes_iv   : std_logic_vector(0 to 127);-- AES IV register
  signal aes_dout : std_logic_vector(0 to 127);-- AES data out register
  signal aes_din  : std_logic_vector(0 to 127);-- AES data in register

  type reg_acc_cnt_t is array (natural range <>) of unsigned(1 downto 0);
  signal read_acc_cnt  : reg_acc_cnt_t(0 to 3);
  signal write_acc_cnt : reg_acc_cnt_t(0 to 2);

  constant REG_RST   : natural := 0;
  constant DEC_START : natural := 1;
  constant ENC_START : natural := 2;
  constant FINISHED  : natural := 3;




begin

  -- Access Control -------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- This logic is required to handle the CPU accesses - DO NOT MODIFY!
  acc_en <= '1' when (addr_i(hi_abb_c downto lo_abb_c) = aes_base_c(hi_abb_c downto lo_abb_c)) else '0';
  addr   <= aes_base_c(31 downto lo_abb_c) & addr_i(lo_abb_c-1 downto 2) & "00"; -- word aligned
  wren   <= acc_en and wren_i; -- only full-word write accesses are supported
  rden   <= acc_en and rden_i; -- read accesses always return a full 32-bit word


  -- CFS Generics ---------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- In it's default version the CFS provides three configuration generics:
  -- > CFS_CONFIG   - is a blank 32-bit generic. It is intended as a "generic conduit" to propagate
  --                  custom configuration flags from the top entity down to this module.


  -- Reset System ---------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- The CFS can be reset using the global rstn_i signal. This signal should be used as asynchronous reset and is active-low.
  -- Note that rstn_i can be asserted by a processor-external reset, the on-chip debugger and also by the watchdog.
  --
  -- Most default peripheral devices of the NEORV32 do NOT use a dedicated hardware reset at all. Instead, these units are
  -- reset by writing ZERO to a specific "control register" located right at the beginning of the device's address space
  -- (so this register is cleared at first). The crt0 start-up code writes ZERO to every single address in the processor's
  -- IO space - including the CFS. Make sure that this initial clearing does not cause any unintended CFS actions.


  -- Interrupt ------------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- The CFS features a single interrupt signal, which is connected to the CPU's "fast interrupt" channel 1 (FIRQ1).
  -- The interrupt is triggered by a one-cycle high-level. After triggering, the interrupt appears as "pending" in the CPU's
  -- mip CSR ready to trigger execution of the according interrupt handler. It is the task of the application to programmer
  -- to enable/clear the CFS interrupt using the CPU's mie and mip registers when required.

  irq_o <= '0'; -- not used for this minimal example


  -- Read/Write Access ----------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- Here we are reading/writing from/to the interface registers of the module and generate the CPU access handshake (bus response).
  --
  -- The CFS provides up to 32 memory-mapped 32-bit interface registers. For instance, these could be used to provide a
  -- <control register> for global control of the unit, a <data register> for reading/writing from/to a data FIFO, a
  -- <command register> for issuing commands and a <status register> for status information.
  --
  -- Following the interface protocol, each read or write access has to be acknowledged in the following cycle using the ack_o
  -- signal (or even later if the module needs additional time). If no ACK is generated at all, the bus access will time out
  -- and cause a bus access fault exception. The current CPU privilege level is available via the 'priv_i' signal (0 = user mode,
  -- 1 = machine mode), which can be used to constrain access to certain registers or features to privileged software only.
  --
  -- This module also provides an optional ERROR signal to indicate a faulty access operation (for example when accessing an
  -- unused, read-only or "locked" CFS register address). This signal may only be set when the module is actually accessed
  -- and is set INSTEAD of the ACK signal. Setting the ERR signal will raise a bus access exception with a "Device Error" qualifier
  -- that can be handled by the application software. Note that the current privilege level should not be exposed to software to
  -- maintain full virtualization. Hence, CFS-based "privilege escalation" should trigger a bus access exception (e.g. by setting 'err_o').

  err_o <= '0'; -- Tie to zero if not explicitly used.


  -- Host access example: Read and write access to the interface registers + bus transfer acknowledge. This example only
  -- implements four physical r/w register (the four lowest CFS registers). The remaining addresses of the CFS are not associated
  -- with any physical registers - any access to those is simply ignored but still acknowledged. Only full-word write accesses are
  -- supported (and acknowledged) by this example. Sub-word write access will not alter any CFS register state and will cause
  -- a "bus store access" exception (with a "Device Timeout" qualifier as not ACK is generated in that case).

  host_access: process (rstn_i, clk_i)
  begin
    if (not rstn_i) then
      aes_ctrl      <= (others => '0');
      aes_key       <= (others => '0');
      aes_iv        <= (others => '0');
      aes_din       <= (others => '0');
      read_acc_cnt  <= (others => "00");
      write_acc_cnt <= (others => "00");
      --
      ack_o  <= '0';
      data_o <= (others => '0');
    elsif rising_edge(clk_i) then -- synchronous interface for read and write accesses
      -- transfer/access acknowledge --
      -- default: required for the CPU to check the CFS is answering a bus read OR write request;
      -- all read and write accesses (to any cfs_reg, even if there is no according physical register implemented) will succeed.
      ack_o <= rden or wren;

      -- write access --
      if (wren) then -- full-word write access, high for one cycle if there is an actual write access
        case addr is
          when aes_ctrl_addr_c => aes_ctrl <= data_i;
                                  if (data_i(REG_RST)) then
                                    aes_key       <= (others => '0');
                                    aes_iv        <= (others => '0');
                                    aes_din       <= (others => '0');
                                    read_acc_cnt  <= (others => "00");
                                    write_acc_cnt <= (others => "00");
                                  end if;
          when aes_key_addr_c  => write_acc_cnt(0) <= write_acc_cnt(0) + 1;
                                  aes_key(to_integer(write_acc_cnt(0))*32 to to_integer(write_acc_cnt(0))*32+31) <= data_i;
          when aes_iv_addr_c   => write_acc_cnt(1) <= write_acc_cnt(1) + 1;
                                  aes_iv(to_integer(write_acc_cnt(1))*32 to to_integer(write_acc_cnt(1))*32+31) <= data_i;
          when aes_din_addr_c  => write_acc_cnt(2) <= write_acc_cnt(2) + 1;
                                  aes_din(to_integer(write_acc_cnt(2))*32 to to_integer(write_acc_cnt(2))*32+31) <= data_i;
          when others          => null;
        end case;
      end if;

      -- read access --
      data_o <= (others => '0'); -- the output HAS TO BE ZERO if there is no actual read access
      if (rden) then -- the read access is always 32-bit wide, high for one cycle if there is an actual read access
        case addr is -- make sure to use the internal 'addr' signal for the read/write interface
          when aes_ctrl_addr_c => data_o <= aes_ctrl;
          when aes_key_addr_c  => read_acc_cnt(0) <= read_acc_cnt(0) + 1;
                                  data_o <= aes_key(to_integer(read_acc_cnt(0))*32 to to_integer(read_acc_cnt(0))*32+31);
          when aes_iv_addr_c   => read_acc_cnt(1) <= read_acc_cnt(1) + 1;
                                  data_o <= aes_iv(to_integer(read_acc_cnt(1))*32 to to_integer(read_acc_cnt(1))*32+31);
          when aes_din_addr_c  => read_acc_cnt(2) <= read_acc_cnt(2) + 1;
                                  data_o <= aes_din(to_integer(read_acc_cnt(2))*32 to to_integer(read_acc_cnt(2))*32+31);
          when aes_dout_addr_c => read_acc_cnt(3) <= read_acc_cnt(3) + 1;
                                  data_o <= aes_dout(to_integer(read_acc_cnt(3))*32 to to_integer(read_acc_cnt(3))*32+31);
          when others          => data_o <= (others => '0'); -- the remaining registers are not implemented and will read as zero
        end case;
      end if;
    end if;
  end process host_access;


  -- CFS Function Core ----------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------

  -- This is where the actual functionality can be implemented.
  -- The logic below is just a very simple example that transforms data
  -- from an input register into data in an output register.

  aes_dout <= aes_din; -- dummy so far


end neorv32_cfs_rtl;
