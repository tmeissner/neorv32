-- #################################################################################################
-- # << NEORV32 - AES Custom Function >>                                                           #
-- # ********************************************************************************************* #
-- # BSD 3-Clause License                                                                          #
-- #                                                                                               #
-- # Copyright (c) 2023, Torsten Meissner. All rights reserved.                                    #
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

library cryptocores;


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
  signal aes_ctrl  : std_logic_vector(31 downto 0);  -- AES control register
  signal aes_key   : std_logic_vector(0 to 127);     -- AES key register
  signal aes_nonce : std_logic_vector(0 to 95);      -- AES nonce register
  signal aes_dout  : std_logic_vector(0 to 127);     -- AES data out register
  signal aes_din   : std_logic_vector(0 to 127);     -- AES data in register

  signal aes_din_accept  : std_logic;
  signal aes_dout_valid  : std_logic;
  signal aes_dout_accept : std_logic;

  type reg_acc_cnt_t is array (natural range <>) of unsigned(1 downto 0);
  signal read_acc_cnt  : reg_acc_cnt_t(0 to 3);
  signal write_acc_cnt : reg_acc_cnt_t(0 to 2);

  constant AES_RESET : natural := 0;  -- Reset key & din registers
  constant CTR_START : natural := 1;  -- 1st round of counter mode
  constant AES_START : natural := 2;  -- start AES engine (cleared with AES_END)
  constant AES_END   : natural := 8;  -- AES engine finished


begin

  -- Access Control -------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- This logic is required to handle the CPU accesses - DO NOT MODIFY!
  acc_en <= '1' when (addr_i(hi_abb_c downto lo_abb_c) = aes_base_c(hi_abb_c downto lo_abb_c)) else '0';
  addr   <= aes_base_c(31 downto lo_abb_c) & addr_i(lo_abb_c-1 downto 2) & "00"; -- word aligned
  wren   <= acc_en and wren_i; -- only full-word write accesses are supported
  rden   <= acc_en and rden_i; -- read accesses always return a full 32-bit word

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


  host_access: process (rstn_i, clk_i) is
  begin
    if (not rstn_i) then
      aes_ctrl      <= (others => '0');
      read_acc_cnt  <= (others => "00");
      write_acc_cnt <= (others => "00");
      -- aes
      aes_dout_accept <= '0';
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
                                  if (data_i(AES_RESET)) then
                                    aes_key       <= (others => '0');
                                    aes_nonce     <= (others => '0');
                                    aes_din       <= (others => '0');
                                    write_acc_cnt <= (others => "00");
                                    read_acc_cnt  <= (others => "00");
                                  end if;
          when aes_key_addr_c  => write_acc_cnt(0) <= write_acc_cnt(0) + 1;
                                  aes_key(to_integer(write_acc_cnt(0))*32 to to_integer(write_acc_cnt(0))*32+31) <= data_i;
          when aes_nonce_addr_c => if (write_acc_cnt(1) = "10") then
                                     write_acc_cnt(1) <= "00";
                                   else
                                     write_acc_cnt(1) <= write_acc_cnt(1) + 1;
                                   end if;
                                   aes_nonce(to_integer(write_acc_cnt(1))*32 to to_integer(write_acc_cnt(1))*32+31) <= data_i;
          when aes_din_addr_c  => write_acc_cnt(1) <= write_acc_cnt(2) + 1;
                                  aes_din(to_integer(write_acc_cnt(2))*32 to to_integer(write_acc_cnt(2))*32+31) <= data_i;
          when others          => null;
        end case;
      end if;

      -- read access --
      data_o          <= (others => '0'); -- the output HAS TO BE ZERO if there is no actual read access
      aes_dout_accept <= '0';
      if (rden) then -- the read access is always 32-bit wide, high for one cycle if there is an actual read access
        case addr is -- make sure to use the internal 'addr' signal for the read/write interface
          when aes_ctrl_addr_c => data_o <= aes_ctrl;
          when aes_key_addr_c  => read_acc_cnt(0) <= read_acc_cnt(0) + 1;
                                  data_o <= aes_key(to_integer(read_acc_cnt(0))*32 to to_integer(read_acc_cnt(0))*32+31);
          when aes_nonce_addr_c => if (read_acc_cnt(1) = "10") then
                                     read_acc_cnt(1) <= "00";
                                   else
                                     read_acc_cnt(1) <= read_acc_cnt(1) + 1;
                                   end if;
                                   data_o <= aes_nonce(to_integer(read_acc_cnt(1))*32 to to_integer(read_acc_cnt(1))*32+31);
          when aes_din_addr_c  => read_acc_cnt(2) <= read_acc_cnt(2) + 1;
                                  data_o <= aes_din(to_integer(read_acc_cnt(2))*32 to to_integer(read_acc_cnt(2))*32+31);
          when aes_dout_addr_c => read_acc_cnt(3) <= read_acc_cnt(3) + 1;
                                  data_o <= aes_dout(to_integer(read_acc_cnt(3))*32 to to_integer(read_acc_cnt(3))*32+31);
                                  if (read_acc_cnt(3) = "11") then
                                    aes_dout_accept <= aes_dout_valid;
                                  end if;
          when others          => data_o <= (others => '0');
        end case;
      end if;

      -- Set AES_END when AES out data is valid
      -- Reset when AES out data was accepted (all 4 dwords of aes_dout were read)
      if (aes_dout_accept) then
        aes_ctrl(AES_END) <= '0';
      elsif (aes_dout_valid) then
        aes_ctrl(AES_END) <= '1';
      end if;

      -- Reset AES_START & CTR_START when AES engine accepts in data
      if (aes_din_accept) then
        aes_ctrl(AES_START) <= '0';
        aes_ctrl(CTR_START) <= '0';
      end if;

    end if;
  end process host_access;


  aes_inst : entity cryptocores.ctraes
  port map (
    reset_i  => rstn_i,
    clk_i    => clk_i,
    start_i  => aes_ctrl(CTR_START),
    nonce_i  => aes_nonce,
    key_i    => aes_key,
    data_i   => aes_din,
    valid_i  => aes_ctrl(AES_START),
    accept_o => aes_din_accept,
    data_o   => aes_dout,
    valid_o  => aes_dout_valid,
    accept_i => aes_dout_accept
  );


end neorv32_cfs_rtl;
