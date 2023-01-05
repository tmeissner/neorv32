library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

library gatemate;
use gatemate.components.all;


architecture neorv32_dmem_rtl of neorv32_dmem is

  -- IO space: module base address --
  constant hi_abb_c : natural := 31; -- high address boundary bit
  constant lo_abb_c : natural := index_size_f(DMEM_SIZE); -- low address boundary bit

  -- local signals --
  signal acc_en : std_ulogic;
  signal rdata  : std_ulogic_vector(31 downto 0);
  signal rden   : std_ulogic;
  signal addr   : std_ulogic_vector(15 downto 0);

  -- -------------------------------------------------------------------------------------------------------------- --
  -- The memory (RAM) is built from 4 individual byte-wide memories b0..b3, since some synthesis tools have         --
  -- problems with 32-bit memories that provide dedicated byte-enable signals AND/OR with multi-dimensional arrays. --
  -- -------------------------------------------------------------------------------------------------------------- --

  -- RAM - not initialized at all --
  signal mem_ram_b0 : mem8_t(0 to DMEM_SIZE/4-1);
  signal mem_ram_b1 : mem8_t(0 to DMEM_SIZE/4-1);
  signal mem_ram_b2 : mem8_t(0 to DMEM_SIZE/4-1);
  signal mem_ram_b3 : mem8_t(0 to DMEM_SIZE/4-1);

  -- read data --
  signal mem_ram_b0_rd, mem_ram_b1_rd, mem_ram_b2_rd, mem_ram_b3_rd : std_ulogic_vector(7 downto 0);

  type mem_ram_rd_t is array (0 to 3) of std_logic_vector(39 downto 0);
  signal mem_ram_rd : mem_ram_rd_t;

begin

  -- Sanity Checks --------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  assert false report "NEORV32 PROCESSOR CONFIG NOTE: Using GateMate CC_BRAM_40K primitives based DMEM." severity note;
  assert false report "NEORV32 PROCESSOR CONFIG NOTE: Implementing processor-internal DMEM (RAM, " & natural'image(DMEM_SIZE) & " bytes)." severity note;
  assert DMEM_SIZE <= 16*1024
    report "NEORV32 PROCESSOR CONFIG ERROR: DMEM size has to be <= 16384 bytes when targetting GateMate FPGA."
    severity error;


  -- Access Control -------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  acc_en <= '1' when (addr_i(hi_abb_c downto lo_abb_c) = DMEM_BASE(hi_abb_c downto lo_abb_c)) else '0';
  addr(15 downto index_size_f(DMEM_SIZE/4)) <= (others => '0');
  addr(index_size_f(DMEM_SIZE/4)-1 downto 0) <= addr_i(index_size_f(DMEM_SIZE/4)+1 downto 2); -- word aligned

  DMEM_ARRAY : for i in 0 to 3 generate

    DRAM : CC_BRAM_40K
    generic map (
      LOC => "UNPLACED",
      CAS => "NONE",
      -- Port Widths
      A_RD_WIDTH => 10,
      B_RD_WIDTH => 10,
      A_WR_WIDTH => 10,
      B_WR_WIDTH => 10,
      -- RAM and Write Modes
      RAM_MODE  => "SDP",
      A_WR_MODE => "NO_CHANGE",
      B_WR_MODE => "NO_CHANGE",
      -- Inverting Control Pins
      A_CLK_INV => '0',
      B_CLK_INV => '0',
      A_EN_INV  => '0',
      B_EN_INV  => '0',
      A_WE_INV  => '0',
      B_WE_INV  => '0',
      -- Output Register
      A_DO_REG => '0',
      B_DO_REG => '0',
      -- Error Checking and Correction
      A_ECC_EN => '0',
      B_ECC_EN => '0'
    )
    port map (
      -- clocks
      A_CLK        => clk_i,
      B_CLK        => clk_i,
      -- inputs
      A_EN         => acc_en,
      B_EN         => acc_en,
      A_WE         => wren_i,
      B_WE         => '0',
      A_ADDR       => addr,
      B_ADDR       => addr,
      A_DI         => 32x"0" & data_i(i*8+7 downto i*8),
      B_DI         => (others => '0'),
      A_BM         => 40x"FF",
      B_BM         => (others => '0'),
      A_CI         => '0',
      B_CI         => '0',
      -- outputs
      A_DO         => open,
      B_DO         => mem_ram_rd(i),
      A_ECC_1B_ERR => open,
      B_ECC_1B_ERR => open,
      A_ECC_2B_ERR => open,
      B_ECC_2B_ERR => open
--      A_CO         => open,
--      B_CO         => open
    );

  end generate;

  mem_ram_b0_rd <= std_ulogic_vector(mem_ram_rd(0)(7 downto 0));
  mem_ram_b1_rd <= std_ulogic_vector(mem_ram_rd(1)(7 downto 0));
  mem_ram_b2_rd <= std_ulogic_vector(mem_ram_rd(2)(7 downto 0));
  mem_ram_b3_rd <= std_ulogic_vector(mem_ram_rd(3)(7 downto 0));


  -- Bus Feedback ---------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  bus_feedback: process(clk_i)
  begin
    if rising_edge(clk_i) then
      rden  <= acc_en and rden_i;
      ack_o <= acc_en and (rden_i or wren_i);
    end if;
  end process bus_feedback;

  -- pack --
  rdata <= mem_ram_b3_rd & mem_ram_b2_rd & mem_ram_b1_rd & mem_ram_b0_rd;

  -- output gate --
  data_o <= rdata when (rden = '1') else (others => '0');


end neorv32_dmem_rtl;
