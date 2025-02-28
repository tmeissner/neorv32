-- #################################################################################################
-- # << NEORV32 - True Random Number Generator (TRNG) >>                                           #
-- # ********************************************************************************************* #
-- # This processor module instantiates the "neoTRNG" true random number generator. An optional    #
-- # "random pool" FIFO can be configured using the TRNG_FIFO generic.                             #
-- # See the neoTRNG's documentation for more information: https://github.com/stnolting/neoTRNG    #
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

entity neorv32_trng is
  generic (
    IO_TRNG_FIFO : natural := 1 -- RND fifo depth, has to be a power of two, min 1
  );
  port (
    -- host access --
    clk_i  : in  std_ulogic; -- global clock line
    rstn_i : in  std_ulogic; -- global reset line, low-active, async
    addr_i : in  std_ulogic_vector(31 downto 0); -- address
    rden_i : in  std_ulogic; -- read enable
    wren_i : in  std_ulogic; -- write enable
    data_i : in  std_ulogic_vector(31 downto 0); -- data in
    data_o : out std_ulogic_vector(31 downto 0); -- data out
    ack_o  : out std_ulogic  -- transfer acknowledge
  );
end neorv32_trng;

architecture neorv32_trng_rtl of neorv32_trng is

  -- neoTRNG Configuration -------------------------------------------------------------------------------------------
  constant num_cells_c     : natural := 3; -- total number of ring-oscillator cells
  constant num_inv_start_c : natural := 3; -- number of inverters in first cell (short path), has to be odd
  constant num_inv_inc_c   : natural := 2; -- number of additional inverters in next cell (short path), has to be even
  constant num_inv_delay_c : natural := 2; -- additional inverters to form cell's long path, has to be even
  -- -----------------------------------------------------------------------------------------------------------------

  -- use simulation mode (PRNG!!!) --
  constant sim_mode_c : boolean := is_simulation_c;

  -- control register bits --
  constant ctrl_data_lsb_c : natural :=  0; -- r/-: Random data byte LSB
  constant ctrl_data_msb_c : natural :=  7; -- r/-: Random data byte MSB
  --
  constant ctrl_fifo_clr_c : natural := 28; -- -/w: Clear data FIFO (auto clears)
  constant ctrl_sim_mode_c : natural := 29; -- r/-: TRNG implemented in PRNG simulation mode
  constant ctrl_en_c       : natural := 30; -- r/w: TRNG enable
  constant ctrl_valid_c    : natural := 31; -- r/-: Output data valid

  -- IO space: module base address --
  constant hi_abb_c : natural := index_size_f(io_size_c)-1; -- high address boundary bit
  constant lo_abb_c : natural := index_size_f(trng_size_c); -- low address boundary bit

  -- access control --
  signal acc_en : std_ulogic; -- module access enable
  signal wren   : std_ulogic; -- full word write enable
  signal rden   : std_ulogic; -- read enable

  -- Component: neoTRNG true random number generator --
  component neoTRNG
    generic (
      NUM_CELLS     : natural; -- total number of ring-oscillator cells
      NUM_INV_START : natural; -- number of inverters in first cell (short path), has to be odd
      NUM_INV_INC   : natural; -- number of additional inverters in next cell (short path), has to be even
      NUM_INV_DELAY : natural; -- additional inverters to form cell's long path, has to be even
      POST_PROC_EN  : boolean; -- implement post-processing for advanced whitening when true
      IS_SIM        : boolean  -- for simulation only!
    );
    port (
      clk_i    : in  std_ulogic; -- global clock line
      enable_i : in  std_ulogic; -- unit enable (high-active), reset unit when low
      data_o   : out std_ulogic_vector(7 downto 0); -- random data byte output
      valid_o  : out std_ulogic  -- data_o is valid when set
    );
  end component;

  -- arbiter --
  signal enable   : std_ulogic;
  signal fifo_clr : std_ulogic;

  -- data FIFO --
  type fifo_t is record
    we    : std_ulogic; -- write enable
    re    : std_ulogic; -- read enable
    clear : std_ulogic; -- sync reset, high-active
    wdata : std_ulogic_vector(7 downto 0); -- write data
    rdata : std_ulogic_vector(7 downto 0); -- read data
    avail : std_ulogic; -- data available?
  end record;
  signal fifo : fifo_t;

begin

  -- Sanity Checks --------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  assert not (IO_TRNG_FIFO < 1) report "NEORV32 PROCESSOR CONFIG ERROR: TRNG FIFO size <IO_TRNG_FIFO> has to be >= 1." severity error;
  assert not (is_power_of_two_f(IO_TRNG_FIFO) = false) report "NEORV32 PROCESSOR CONFIG ERROR: TRNG FIFO size <IO_TRNG_FIFO> has to be a power of two." severity error;
  assert not (sim_mode_c = true) report "NEORV32 PROCESSOR CONFIG WARNING: TRNG uses SIMULATION mode!" severity warning;


  -- Access Control -------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  acc_en <= '1' when (addr_i(hi_abb_c downto lo_abb_c) = trng_base_c(hi_abb_c downto lo_abb_c)) else '0';
  wren   <= acc_en and wren_i;
  rden   <= acc_en and rden_i;


  -- Write Access ---------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  write_access: process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      enable   <= '0';
      fifo_clr <= '0';
    elsif rising_edge(clk_i) then
      fifo_clr <= '0'; -- default
      if (wren = '1') then
        enable   <= data_i(ctrl_en_c);
        fifo_clr <= data_i(ctrl_fifo_clr_c);
      end if;
    end if;
  end process write_access;


  -- Read Access ----------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  read_access: process(clk_i)
  begin
    if rising_edge(clk_i) then
      ack_o  <= wren or rden; -- host bus acknowledge
      data_o <= (others => '0');
      if (rden = '1') then
        data_o(ctrl_data_msb_c downto ctrl_data_lsb_c) <= fifo.rdata;
        --
        data_o(ctrl_sim_mode_c) <= bool_to_ulogic_f(sim_mode_c);
        data_o(ctrl_en_c)       <= enable;
        data_o(ctrl_valid_c)    <= fifo.avail;
      end if;
    end if;
  end process read_access;


  -- neoTRNG True Random Number Generator ---------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  neoTRNG_inst: neoTRNG
    generic map (
      NUM_CELLS     => num_cells_c,
      NUM_INV_START => num_inv_start_c,
      NUM_INV_INC   => num_inv_inc_c,
      NUM_INV_DELAY => num_inv_delay_c,
      POST_PROC_EN  => true, -- post-processing enabled to improve "random quality"
      IS_SIM        => sim_mode_c
    )
    port map (
      clk_i    => clk_i,
      enable_i => enable,
      data_o   => fifo.wdata,
      valid_o  => fifo.we
    );


  -- Data FIFO ("Random Pool") --------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  rnd_pool_fifo_inst: neorv32_fifo
  generic map (
    FIFO_DEPTH => IO_TRNG_FIFO, -- number of fifo entries; has to be a power of two; min 1
    FIFO_WIDTH => 8,            -- size of data elements in fifo
    FIFO_RSYNC => false,        -- async read
    FIFO_SAFE  => true,         -- safe access
    FIFO_GATE  => true          -- make sure the same RND data byte cannot be read twice
  )
  port map (
    -- control --
    clk_i   => clk_i,      -- clock, rising edge
    rstn_i  => rstn_i,     -- async reset, low-active
    clear_i => fifo.clear, -- sync reset, high-active
    half_o  => open,
    -- write port --
    wdata_i => fifo.wdata, -- write data
    we_i    => fifo.we,    -- write enable
    free_o  => open,       -- at least one entry is free when set
    -- read port --
    re_i    => fifo.re,    -- read enable
    rdata_o => fifo.rdata, -- read data
    avail_o => fifo.avail  -- data available when set
  );

  -- fifo reset --
  fifo.clear <= '1' when (enable = '0') or (fifo_clr = '1') else '0';

  -- read access --
  fifo.re <= '1' when (rden = '1') else '0';


end neorv32_trng_rtl;


-- ############################################################################################################################
-- ############################################################################################################################


-- #################################################################################################
-- # << neoTRNG V2 - A Tiny and Platform-Independent True Random Number Generator for any FPGA >>  #
-- # ********************************************************************************************* #
-- # This generator is based on entropy cells, which implement simple ring-oscillators. Each ring- #
-- # oscillator features a short and a long delay path that is dynamically switched. The cells are #
-- # cascaded so that the random data output of a cell controls the delay path of the next cell.   #
-- #                                                                                               #
-- # The random data output of the very last cell in the chain is synchronized and de-biased using #
-- # a simple 2-bit a von Neumann randomness extractor (converting edges into bits). Eight result  #
-- # bits are samples to create one "raw" random data sample. If the post-processing module is     #
-- # enabled (POST_PROC_EN), 8 byte samples will be combined into a single output byte to improve  #
-- # whitening.                                                                                    #
-- #                                                                                               #
-- # The entropy cell architecture uses individually-controlled latches and inverters to create    #
-- # the inverter chain in a platform-agnostic style that can be implemented for any FPGA without  #
-- # requiring primitive instantiation or technology-specific attributes.                          #
-- #                                                                                               #
-- # See the neoTRNG's documentation for more information: https://github.com/stnolting/neoTRNG    #
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
-- # neoTRNG - https://github.com/stnolting/neoTRNG                            (c) Stephan Nolting #
-- #################################################################################################

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity neoTRNG is
  generic (
    NUM_CELLS     : natural; -- total number of ring-oscillator cells
    NUM_INV_START : natural; -- number of inverters in first cell (short path), has to be odd
    NUM_INV_INC   : natural; -- number of additional inverters in next cell (short path), has to be even
    NUM_INV_DELAY : natural; -- additional inverters to form cell's long path, has to be even
    POST_PROC_EN  : boolean; -- implement post-processing for advanced whitening when true
    IS_SIM        : boolean  -- for simulation only!
  );
  port (
    clk_i    : in  std_ulogic; -- global clock line
    enable_i : in  std_ulogic; -- unit enable (high-active), reset unit when low
    data_o   : out std_ulogic_vector(7 downto 0); -- random data byte output
    valid_o  : out std_ulogic  -- data_o is valid when set
  );
end neoTRNG;

architecture neoTRNG_rtl of neoTRNG is

  -- Component: neoTRNG entropy cell --
  component neoTRNG_cell
    generic (
      NUM_INV_S : natural; -- number of inverters in short path
      NUM_INV_L : natural; -- number of inverters in long path
      IS_SIM    : boolean  -- for simulation only!
    );
    port (
      clk_i    : in  std_ulogic; -- system clock
      select_i : in  std_ulogic; -- delay select
      enable_i : in  std_ulogic; -- enable chain input
      enable_o : out std_ulogic; -- enable chain output
      data_o   : out std_ulogic  -- random data
    );
  end component;

  -- ring-oscillator array interconnect --
  type cell_array_t is record
    en_in  : std_ulogic_vector(NUM_CELLS-1 downto 0);
    en_out : std_ulogic_vector(NUM_CELLS-1 downto 0);
    output : std_ulogic_vector(NUM_CELLS-1 downto 0);
    input  : std_ulogic_vector(NUM_CELLS-1 downto 0);
  end record;
  signal cell_array : cell_array_t;

  -- raw synchronizer --
  signal rnd_sync : std_ulogic_vector(1 downto 0);

  -- von-Neumann de-biasing --
  type debiasing_t is record
    sreg  : std_ulogic_vector(1 downto 0);
    state : std_ulogic; -- process de-biasing every second cycle
    valid : std_ulogic; -- de-biased data
    data  : std_ulogic; -- de-biased data valid
  end record;
  signal db : debiasing_t;

  -- sample unit --
  type sample_t is record
    enable : std_ulogic;
    run    : std_ulogic;
    sreg   : std_ulogic_vector(7 downto 0); -- data shift register
    valid  : std_ulogic; -- valid data sample (one byte)
    cnt    : std_ulogic_vector(2 downto 0); -- bit counter
  end record;
  signal sample : sample_t;

  -- post processing --
  type post_t is record
    state : std_ulogic_vector(1 downto 0);
    cnt   : std_ulogic_vector(3 downto 0); -- byte counter
    buf   : std_ulogic_vector(7 downto 0); -- post processing buffer
    valid : std_ulogic; -- valid data byte
  end record;
  signal post : post_t;

begin

  -- Sanity Checks --------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  assert not (true) report "<< neoTRNG V2 - A Tiny and Platform-Independent True Random Number Generator for any FPGA >>" severity note;
  assert not (POST_PROC_EN = true) report "neoTRNG note: Post-processing enabled." severity note;
  assert not (IS_SIM = true) report "neoTRNG WARNING: Simulation mode (PRNG!) enabled!" severity warning;
  assert not (NUM_CELLS < 2) report "neoTRNG config ERROR: Total number of ring-oscillator cells <NUM_CELLS> has to be >= 2." severity error;
  assert not ((NUM_INV_START mod 2)  = 0) report "neoTRNG config ERROR: Number of inverters in first cell <NUM_INV_START> has to be odd." severity error;
  assert not ((NUM_INV_INC   mod 2) /= 0) report "neoTRNG config ERROR: Inverter increment for each next cell <NUM_INV_INC> has to be even." severity error;
  assert not ((NUM_INV_DELAY mod 2) /= 0) report "neoTRNG config ERROR: Inverter increment to form long path <NUM_INV_DELAY> has to be even." severity error;


  -- Entropy Source -------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  neoTRNG_cell_inst:
  for i in 0 to NUM_CELLS-1 generate
    neoTRNG_cell_inst_i: neoTRNG_cell
    generic map (
      NUM_INV_S => NUM_INV_START + (i*NUM_INV_INC), -- number of inverters in short chain
      NUM_INV_L => NUM_INV_START + (i*NUM_INV_INC) + NUM_INV_DELAY, -- number of inverters in long chain
      IS_SIM    => IS_SIM -- for simulation only!
    )
    port map (
      clk_i    => clk_i,
      select_i => cell_array.input(i),
      enable_i => cell_array.en_in(i),
      enable_o => cell_array.en_out(i),
      data_o   => cell_array.output(i) -- SYNC data output
    );
  end generate;

  -- enable chain --
  cell_array.en_in(0) <= sample.enable; -- start of chain
  cell_array.en_in(NUM_CELLS-1 downto 1) <= cell_array.en_out(NUM_CELLS-2 downto 0); -- i+1 <= i

  -- feedback chain --
  path_select: process(rnd_sync, cell_array.output)
  begin
    if (rnd_sync(0) = '0') then -- forward
      cell_array.input(0) <= cell_array.output(NUM_CELLS-1);
      for i in 0 to NUM_CELLS-2 loop
        cell_array.input(i+1) <= cell_array.output(i);
      end loop;
    else -- backward
      cell_array.input(NUM_CELLS-1) <= cell_array.output(0);
      for i in NUM_CELLS-1 downto 1 loop
        cell_array.input(i-1) <= cell_array.output(i);
      end loop;
    end if;
  end process path_select;


  -- Synchronizer ---------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  synchronizer: process(clk_i)
  begin
    -- no more metastability beyond this point --
    if rising_edge(clk_i) then
      rnd_sync(1) <= rnd_sync(0);
      rnd_sync(0) <= cell_array.output(NUM_CELLS-1);
    end if;
  end process synchronizer;


  -- John von Neumann Randomness Extractor (De-Biasing) -------------------------------------
  -- -------------------------------------------------------------------------------------------
  debiasing_sync: process(clk_i)
  begin
    if rising_edge(clk_i) then
      db.sreg <= db.sreg(0) & rnd_sync(rnd_sync'left);
      -- start operation when last cell is enabled and process in every second cycle --
      db.state <= (not db.state) and cell_array.en_out(NUM_CELLS-1);
    end if;
  end process debiasing_sync;

  -- edge detector --
  debiasing_comb: process(db)
    variable tmp_v : std_ulogic_vector(2 downto 0);
  begin
    tmp_v := db.state & db.sreg(1 downto 0); -- check groups of two non-overlapping bits from the input stream
    case tmp_v is
      when "101"  => db.valid <= '1'; -- rising edge
      when "110"  => db.valid <= '1'; -- falling edge
      when others => db.valid <= '0'; -- no valid data
    end case;
  end process debiasing_comb;

  -- edge data --
  db.data <= db.sreg(0);


  -- Sample Unit ----------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  sample_unit: process(clk_i)
  begin
    if rising_edge(clk_i) then
      sample.enable <= enable_i;

      -- sample chunks of 8 bit --
      if (sample.enable = '0') then
        sample.cnt <= (others => '0');
        sample.run <= '0';
      elsif (db.valid = '1') then -- valid random sample?
        sample.cnt <= std_ulogic_vector(unsigned(sample.cnt) + 1);
        sample.run <= '1';
      end if;

      -- sample shift register --
      if (db.valid = '1') then
        sample.sreg <= sample.sreg(sample.sreg'left-1 downto 0) & db.data;
      end if;

      -- sample valid? --
      if (sample.cnt = "000") and (sample.run = '1') and (db.valid = '1') then
        sample.valid <= '1';
      else
        sample.valid <= '0';
      end if;
    end if;
  end process sample_unit;


  -- Post Processing ------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  post_processing_enable:
  if (POST_PROC_EN = true) generate

    post_processing: process(clk_i)
    begin
      if rising_edge(clk_i) then
        -- defaults --
        post.state(1) <= sample.run;
        post.valid    <= '0';

        -- fsm --
        case post.state is

          when "10" => -- start new post-processing
            post.cnt      <= (others => '0');
            post.buf      <= (others => '0');
            post.state(0) <= '1';

          when "11" => -- combine eight samples
            if (sample.valid = '1') then
              post.buf <= std_ulogic_vector(unsigned(post.buf(0) & post.buf(7 downto 1)) + unsigned(sample.sreg)); -- combine function
              post.cnt <= std_ulogic_vector(unsigned(post.cnt) + 1);
            end if;
            if (post.cnt(3) = '1') then
              post.valid    <= '1';
              post.state(0) <= '0';
            end if;

          when others => -- reset/disabled
            post.state(0) <= '0';

        end case;
      end if;
    end process post_processing;

    -- data output --
    data_o  <= post.buf;
    valid_o <= post.valid;

  end generate; -- /post_processing_enable

  post_processing_disable:
  if (POST_PROC_EN = false) generate
    -- data output --
    data_o  <= sample.sreg;
    valid_o <= sample.valid;
  end generate;


end neoTRNG_rtl;


-- ############################################################################################################################
-- ############################################################################################################################


-- #################################################################################################
-- # << neoTRNG V2 - A Tiny and Platform-Independent True Random Number Generator for any FPGA >>  #
-- # ********************************************************************************************* #
-- # neoTRNG Entropy Cell                                                                          #
-- #                                                                                               #
-- # The cell consists of two ring-oscillators build from inverter chains. The short chain uses    #
-- # NUM_INV_S inverters and oscillates at a "high" frequency and the long chain uses NUM_INV_L    #
-- # inverters and oscillates at a "low" frequency. The select_i input selects which chain is      #
-- # used as data output (data_o).                                                                 #
-- #                                                                                               #
-- # Each inverter chain is constructed as an "asynchronous" shift register. The single inverters  #
-- # are connected via latches that are used to enable/disable the TRNG. Also, these latches are   #
-- # used as additional delay element. By using unique enable signals for each latch, the          #
-- # synthesis tool cannot "optimize" (=remove) any of the inverters out of the design making the  #
-- # design platform-agnostic.                                                                     #
-- # ********************************************************************************************* #
-- # BSD 3-Clause License                                                                          #
-- #                                                                                               #
-- # Copyright (c) 2021, Stephan Nolting. All rights reserved.                                     #
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
-- # neoTRNG - https://github.com/stnolting/neoTRNG                            (c) Stephan Nolting #
-- #################################################################################################

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity neoTRNG_cell is
  generic (
    NUM_INV_S : natural; -- number of inverters in short path
    NUM_INV_L : natural; -- number of inverters in long path
    IS_SIM    : boolean  -- for simulation only!
  );
  port (
    clk_i    : in  std_ulogic; -- system clock
    select_i : in  std_ulogic; -- delay select
    enable_i : in  std_ulogic; -- enable chain input
    enable_o : out std_ulogic; -- enable chain output
    data_o   : out std_ulogic  -- random data
  );
end neoTRNG_cell;

architecture neoTRNG_cell_rtl of neoTRNG_cell is

  signal inv_chain_s   : std_ulogic_vector(NUM_INV_S-1 downto 0); -- short oscillator chain
  signal inv_chain_l   : std_ulogic_vector(NUM_INV_L-1 downto 0); -- long oscillator chain
  signal feedback      : std_ulogic; -- cell feedback/output
  signal enable_sreg_s : std_ulogic_vector(NUM_INV_S-1 downto 0); -- enable shift register for short chain
  signal enable_sreg_l : std_ulogic_vector(NUM_INV_L-1 downto 0); -- enable shift register for long chain
  signal lfsr          : std_ulogic_vector(15 downto 0); -- LFSR - for simulation only!!!

begin

  -- Ring Oscillator ------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- Each cell provides a short inverter chain (high frequency) and a long oscillator chain (low frequency).
  -- The select_i signals defines which chain is used as cell output.
  -- NOTE: All signals that control a inverter-latch element have to be registered to ensure a single element
  -- is mapped to a single LUT (or LUT + FF(latch-mode)).

  real_hardware:
  if (IS_SIM = false) generate

    -- short oscillator chain --
    ring_osc_short: process(enable_i, enable_sreg_s, feedback, inv_chain_s)
    begin
      for i in 0 to NUM_INV_S-1 loop -- inverters in short chain
        if (enable_i = '0') then -- start with a defined state (latch reset)
          inv_chain_s(i) <= '0';
        elsif (enable_sreg_s(i) = '1') then
          if (i = NUM_INV_S-1) then -- left-most inverter?
            inv_chain_s(i) <= not feedback;
          else
            inv_chain_s(i) <= not inv_chain_s(i+1);
          end if;
        end if;
      end loop; -- i
    end process ring_osc_short;

    -- long oscillator chain --
    ring_osc_long: process(enable_i, enable_sreg_l, feedback, inv_chain_l)
    begin
      for i in 0 to NUM_INV_L-1 loop -- inverters in long chain
        if (enable_i = '0') then -- start with a defined state (latch reset)
          inv_chain_l(i) <= '0';
        elsif (enable_sreg_l(i) = '1') then
          if (i = NUM_INV_L-1) then -- left-most inverter?
            inv_chain_l(i) <= not feedback;
          else
            inv_chain_l(i) <= not inv_chain_l(i+1);
          end if;
        end if;
      end loop; -- i
    end process ring_osc_long;

    -- final ROSC output --
    feedback <= inv_chain_l(0) when (select_i = '1') else inv_chain_s(0);
    data_o   <= feedback;
  end generate;


  -- Fake(!) Pseudo-RNG ---------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- For simulation/debugging only! --
  sim_rng:
  if (IS_SIM = true) generate
    assert false report "neoTRNG WARNING: Implementing simulation-only PRNG (LFSR)!" severity warning;
    sim_lfsr: process(clk_i)
    begin
      if rising_edge(clk_i) then
        if (enable_sreg_l(enable_sreg_l'left) = '0') then
          lfsr <= std_ulogic_vector(to_unsigned(NUM_INV_S, 16));
        else
          lfsr <= lfsr(lfsr'left-1 downto 0) & (lfsr(15) xnor lfsr(14) xnor lfsr(13) xnor lfsr(2));
        end if;
      end if;
    end process sim_lfsr;

    feedback <= lfsr(lfsr'left);
    data_o   <= feedback;
  end generate;


  -- Control --------------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- Using individual enable signals for each inverter from a shift register to prevent the synthesis tool
  -- from removing all but one inverter (since they implement "logical identical functions" (='toggle')).
  -- This makes the TRNG platform independent (since we do not need to use primitives to ensure a correct architecture).
  ctrl_unit: process(clk_i)
  begin
    if rising_edge(clk_i) then
      enable_sreg_s <= enable_sreg_s(enable_sreg_s'left-1 downto 0) & enable_i;
      enable_sreg_l <= enable_sreg_l(enable_sreg_l'left-1 downto 0) & enable_sreg_s(enable_sreg_s'left);
    end if;
  end process ctrl_unit;

  -- output for "enable chain" --
  enable_o <= enable_sreg_l(enable_sreg_l'left);


end neoTRNG_cell_rtl;

