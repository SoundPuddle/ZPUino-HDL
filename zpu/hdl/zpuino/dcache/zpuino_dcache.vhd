library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.std_logic_unsigned.all;

use ieee.numeric_std.all;

library work;
use work.zpu_config.all;
use work.zpupkg.all;
use work.zpuinopkg.all;
use work.wishbonepkg.all;
-- synopsys translate_off
use work.txt_util.all;
-- synopsys translate_on


entity zpuino_dcache is
  generic (
      ADDRESS_HIGH: integer := 26;
      CACHE_MAX_BITS: integer := 13; -- 8 Kb
      CACHE_LINE_SIZE_BITS: integer := 6 -- 64 bytes
  );
  port (
    syscon:     in wb_syscon_type;
    ci:         in dcache_in_type;
    co:         out dcache_out_type;
    mwbi:       in wb_miso_type;
    mwbo:       out wb_mosi_type
  );
end zpuino_dcache;

architecture behave of zpuino_dcache is
  
  constant CACHE_LINE_ID_BITS: integer := CACHE_MAX_BITS-CACHE_LINE_SIZE_BITS;

  subtype address_type is std_logic_vector(ADDRESS_HIGH downto 2);
  -- A line descriptor
  subtype line_number_type is std_logic_vector(CACHE_LINE_ID_BITS-1 downto 0);
  -- Offset within a line
  subtype line_offset_type is std_logic_vector(CACHE_LINE_SIZE_BITS-1-2 downto 0);
  -- A tag descriptor
  subtype tag_type is std_logic_vector((ADDRESS_HIGH-CACHE_MAX_BITS) downto 0);
  -- A full tag memory descriptor. Includes valid bit and dirty bit
  subtype full_tag_type is std_logic_vector(ADDRESS_HIGH-CACHE_MAX_BITS+2 downto 0);

  constant VALID: integer := ADDRESS_HIGH-CACHE_MAX_BITS+1;
  constant DIRTY: integer := ADDRESS_HIGH-CACHE_MAX_BITS+2;
  ------------------------------------------------------------------------------

  type state_type is (
    idle,
    readline,
    writeback,
    write_after_fill,
    settle,
    flush
  );

  type regs_type is record
    a_req:            std_logic;
    b_req:            std_logic;
    a_req_addr:       address_type;
    b_req_addr:       address_type;
    b_req_we:         std_logic;
    b_req_wmask:      std_logic_vector(3 downto 0);
    b_req_data:       std_logic_vector(wordSize-1 downto 0);
    fill_offset_r:    line_offset_type;
    fill_offset_w:    line_offset_type;
    fill_tag:         tag_type;
    fill_line_number: line_number_type;
    flush_line_number: line_number_type;
    fill_r_done:      std_logic;
    fill_is_b:        std_logic;
    ack_b_write:      std_logic;
    writeback_tag:    tag_type;
    state:            state_type;
    misses:           integer;
    rvalid:           std_logic;
    wr_conflict:      std_logic;
    flush_req:        std_logic;
    in_flush:         std_logic;
  end record;

  function address_to_tag(a: in address_type) return tag_type is
    variable t: tag_type;
  begin
    t:= a(ADDRESS_HIGH downto CACHE_MAX_BITS);
    return t;
  end address_to_tag;

  function address_to_line_number(a: in address_type) return line_number_type is
    variable r: line_number_type;
  begin
    r:=a(CACHE_MAX_BITS-1 downto CACHE_LINE_SIZE_BITS);
    return r;
  end address_to_line_number;

  function address_to_line_offset(a: in address_type) return line_offset_type is
    variable r: line_offset_type;
  begin
    r:=a(CACHE_LINE_SIZE_BITS-1 downto 2);
    return r;
  end address_to_line_offset;

  ------------------------------------------------------------------------------


  -- extracted values from port A
  signal a_line_number:   line_number_type;

  -- extracted values from port B
  signal b_line_number:   line_number_type;

  -- Some helpers
  signal a_hit: std_logic;
  signal a_miss: std_logic;
  signal b_miss: std_logic;
  signal a_b_conflict: std_logic;
  
  -- Connection to tag memory

  signal tmem_ena:    std_logic;
  signal tmem_wea:    std_logic;
  signal tmem_addra:  line_number_type;
  signal tmem_dia:    full_tag_type;
  signal tmem_doa:    full_tag_type;
  signal tmem_enb:    std_logic;
  signal tmem_web:    std_logic;
  signal tmem_addrb:  line_number_type;
  signal tmem_dib:    full_tag_type;
  signal tmem_dob:    full_tag_type;

  signal cmem_ena:    std_logic;
  signal cmem_wea:    std_logic_vector(3 downto 0);
  signal cmem_dia:    std_logic_vector(wordSize-1 downto 0);
  signal cmem_doa:    std_logic_vector(wordSize-1 downto 0);
  signal cmem_addra:  std_logic_vector(CACHE_MAX_BITS-1 downto 2);

  signal cmem_enb:    std_logic;
  signal cmem_web:    std_logic_vector(3 downto 0);
  signal cmem_dib:    std_logic_vector(wordSize-1 downto 0);
  signal cmem_dob:    std_logic_vector(wordSize-1 downto 0);
  signal cmem_addrb:  std_logic_vector(CACHE_MAX_BITS-1 downto 2);

  signal r: regs_type;
  signal same_address: std_logic;

  constant offset_all_ones: line_offset_type := (others => '1');
  constant line_number_all_ones: line_number_type := (others => '1');

  signal dbg_a_valid: std_logic;
  signal dbg_b_valid: std_logic;
  signal dbg_a_dirty: std_logic;
  signal dbg_b_dirty: std_logic;

begin

  -- These are alias, but written as signals so we can inspect them

  a_line_number <= address_to_line_number(ci.a_address(address_type'RANGE));
  b_line_number <= address_to_line_number(ci.b_address(address_type'RANGE));

  -- TAG memory

  tagmem: generic_dp_ram_rf
  generic map (
    address_bits  => CACHE_LINE_ID_BITS,
    data_bits     => ADDRESS_HIGH-CACHE_MAX_BITS+3
  )
  port map (
    clka      => syscon.clk,
    ena       => tmem_ena,
    wea       => tmem_wea,
    addra     => tmem_addra,
    dia       => tmem_dia,
    doa       => tmem_doa,

    clkb      => syscon.clk,
    enb       => tmem_enb,
    web       => tmem_web,
    addrb     => tmem_addrb,
    dib       => tmem_dib,
    dob       => tmem_dob
  );

  -- Cache memory
  memgen: for i in 0 to 3 generate

  cachemem: generic_dp_ram_rf
  generic map (
    address_bits => cmem_addra'LENGTH,
    data_bits => 8
  )
  port map (
    clka      => syscon.clk,
    ena       => cmem_ena,
    wea       => cmem_wea(i),
    addra     => cmem_addra,
    dia       => cmem_dia(((i+1)*8)-1 downto i*8),
    doa       => cmem_doa(((i+1)*8)-1 downto i*8),

    clkb      => syscon.clk,
    enb       => cmem_enb,
    web       => cmem_web(i),
    addrb     => cmem_addrb,
    dib       => cmem_dib(((i+1)*8)-1 downto i*8),
    dob       => cmem_dob(((i+1)*8)-1 downto i*8)
  );

  end generate;

  process(r,syscon.clk,syscon.rst, ci, mwbi, tmem_doa, a_miss,b_miss,
          tmem_doa, tmem_dob, a_line_number, b_line_number, cmem_doa, cmem_dob)
    variable w: regs_type;
    variable a_have_request: std_logic;
    variable b_have_request: std_logic;
    variable a_will_busy: std_logic;
    variable b_will_busy: std_logic;
    variable wr_conflict: std_logic;
  begin
    w := r;
    co.a_valid<='0';
    co.b_valid<='0';
    co.a_stall<='0';
    co.b_stall<='0';
    a_miss <='0';
    b_miss <='0';
    a_will_busy := '0';
    b_will_busy := '0';

    a_b_conflict <='0';
    mwbo.cyc <= '0';
    mwbo.stb <= DontCareValue;
    mwbo.adr <= (others => DontCareValue);
    mwbo.dat <= (others => DontCareValue);
    mwbo.we <= DontCareValue;
    mwbo.sel<=(others => '1');

    tmem_addra <= a_line_number;
    tmem_addrb <= b_line_number;
    tmem_ena <= '1';
    tmem_wea <= '0';
    tmem_enb <= '1';
    tmem_web <= '0';
    tmem_dib(tag_type'RANGE) <= address_to_tag(ci.b_address(r.b_req_addr'RANGE));--(others => DontCareValue);
    tmem_dib(DIRTY)<=DontCareValue;
    tmem_dib(VALID)<=DontCareValue;

    tmem_dia <= (others => DontCareValue);


    cmem_addra <= ci.a_address(CACHE_MAX_BITS-1 downto 2);
    cmem_addrb <= ci.b_address(CACHE_MAX_BITS-1 downto 2);
    cmem_ena <= ci.a_enable;
    cmem_wea <= (others =>'0');
    cmem_web <= ci.b_wmask;--(others =>'0');  -- NOTE: or with we?
    cmem_enb <= ci.b_enable;
    cmem_dia <= (others => DontCareValue); -- No writes on port A
    cmem_dib <= ci.b_data_in;--(others => DontCareValue);

    co.a_data_out <= cmem_doa;
    co.b_data_out <= cmem_dob;

    w.ack_b_write := '0';
    w.rvalid := '0';

    dbg_a_valid <= tmem_doa(VALID);
    dbg_b_valid <= tmem_dob(VALID);

    dbg_a_dirty <= tmem_doa(DIRTY);
    dbg_b_dirty <= tmem_dob(DIRTY);
    wr_conflict := '0';

    case r.state is
      when idle =>

        -- Now, after reading from tag memory....
        if (r.a_req='1') then
          -- We had a request, check
          a_miss<='1';
          if tmem_doa(VALID)='1' then
            if tmem_doa(tag_type'RANGE) = address_to_tag(r.a_req_addr) then
              a_miss<='0';
            end if;
          end if;
        else
          a_miss<='0';
        end if;

        if (r.b_req='1') then
          -- We had a request, check
          b_miss<='1';
          if tmem_dob(VALID)='1' then
            if tmem_dob(tag_type'RANGE) = address_to_tag(r.b_req_addr) then
              b_miss<='0';
            end if;
          end if;
        else
          b_miss<='0';
        end if;

        -- Conflict
        if (r.a_req='1' and r.b_req='1') then
          -- We have a conflict if we're accessing the same line, but however
          -- the tags mismatch

          if address_to_line_number(r.a_req_addr) = address_to_line_number(r.b_req_addr) and
            --tmem_dob(tag_type'RANGE) /= tmem_doa(tag_type'RANGE) then
            address_to_tag(r.a_req_addr) /= address_to_tag(r.b_req_addr) then

            -- synopsys translate_off
            report "Conflict" & hstr(tmem_dob) severity failure;
            -- synopsys translate_on

          end if;                               
        end if;

        -- Miss handling
        if r.a_req='1' then
        if a_miss='1' then
          co.a_stall <= '1';
          --b_stall <= '1';
          co.a_valid <= '0';
          --b_valid <= '0';
          w.misses := r.misses+1;
          w.fill_tag := address_to_tag(r.a_req_addr);
          w.fill_line_number := address_to_line_number(r.a_req_addr);
          w.fill_offset_r := (others => '0');
          w.fill_offset_w := (others => '0');
          w.fill_r_done := '0';
          w.fill_is_b := '0';

          if tmem_doa(VALID)='1' then
            if tmem_doa(DIRTY)='1' then
              w.writeback_tag := tmem_doa(tag_type'RANGE);
              w.state := writeback;
              a_will_busy :='1';
            else
              w.state := readline;
              a_will_busy :='1';
            end if;
          else
            w.state := readline;
            a_will_busy :='1';
          end if;
        else
          -- if we're writing to a similar address, delay for one clock cycle
          --if r.b_req='1' and r.b_req_we='1' and address_to_line_offset(r.b_req_addr)=address_to_line_offset(r.a_req_addr) then
          if r.wr_conflict='1' then
            co.a_valid<='0';
            co.a_stall<='1';
            a_will_busy :='1';
            cmem_addra <= r.a_req_addr(CACHE_MAX_BITS-1 downto 2);--r.fill_tag & r.fill_line_number & r.fill_offset_w;
            tmem_addra <= address_to_line_number(r.a_req_addr);
          else
            co.a_valid <= '1';
          end if;
        end if;
        end if;



        -- Miss handling (B)
        if r.b_req='1' then
        if b_miss='1' and a_miss='0' then
          co.b_stall <= '1';
          w.misses := r.misses+1;
          --a_stall <= '1';
          co.b_valid <= '0';
          b_will_busy :='1';
          --a_valid <= '0';

          w.fill_tag := address_to_tag(r.b_req_addr);
          w.fill_line_number := address_to_line_number(r.b_req_addr);
          w.fill_offset_r := (others => '0');
          w.fill_offset_w := (others => '0');
          w.fill_r_done := '0';
          w.fill_is_b := '1';

          if tmem_dob(VALID)='1' then
            if tmem_dob(DIRTY)='1' then
              -- need to recover data - we overwrote it ...
              w.writeback_tag := tmem_dob(tag_type'RANGE);

              cmem_dib <= cmem_dob;
              cmem_addrb <= r.b_req_addr(CACHE_MAX_BITS-1 downto 2);
              cmem_web <= (others => '1');
              cmem_enb <= '1';

              w.state := writeback;
            else
              w.state := readline;
            end if;
          else
            w.state := readline;
          end if;
        else
          if a_miss='0' and b_miss='0' then


            -- Process writes, line is in cache
            if r.b_req_we='1' then
              --co.b_stall <= '1'; -- Stall everything.
              --b_will_busy <= '1';

              -- Now, we need to re-write tag so to set dirty to '1'
              --tmem_addrb <= address_to_line_number(r.b_req_addr);
              --tmem_dib(tag_type'RANGE) <=address_to_tag(r.b_req_addr);
              --tmem_dib(VALID)<='1';
              --tmem_dib(DIRTY)<='1';
              --tmem_web<='1';
              --tmem_enb<='1';

              --cmem_addrb <= r.b_req_addr(CACHE_MAX_BITS-1 downto 2);
              --cmem_dib <= r.b_req_data;
              --cmem_web <= r.b_req_wmask;
              --cmem_enb <= '1';

              w.ack_b_write:='1';
              --w.state := settle;

            else
              co.b_valid <= '1';
            end if;
          else
            b_will_busy :='1';
            co.b_stall <= '1';
          end if;
        end if;
        end if;


        if r.flush_req='1' then
          a_will_busy :='1';
          co.a_stall <= '1';
          b_will_busy :='1';
          co.b_stall <= '1';
          w.state := flush;
          w.fill_line_number := (others => '0');
          w.flush_line_number := (others => '0');
        end if;

        a_have_request := '0';

        -- Queue requests
        if a_will_busy='0' then
          w.a_req := ci.a_strobe and ci.a_enable;
          if ci.a_strobe='1' and ci.a_enable='1' then
            a_have_request := '1';
            w.a_req_addr := ci.a_address(address_type'RANGE);
          end if;
        end if;

        tmem_web <= '0';

        b_have_request := '0';
        if b_will_busy='0' then
          w.b_req := ci.b_strobe and ci.b_enable;
          if ci.b_strobe='1' and ci.b_enable='1' then
            b_have_request := '1';
            w.b_req_addr := ci.b_address(address_type'RANGE);
            w.b_req_we := ci.b_we;
            tmem_web <= ci.b_we;
            tmem_dib(VALID)<='1';
            tmem_dib(DIRTY)<='1';

            w.b_req_wmask := ci.b_wmask;
            w.b_req_data := ci.b_data_in;
          end if;
        end if;

        wr_conflict := '0';
        if a_have_request='1' and b_have_request='1' and
          ci.a_address(address_type'RANGE)=ci.b_address(address_type'RANGE) then
          wr_conflict := '1';
        end if;
        w.wr_conflict := wr_conflict;

      when readline =>
        co.a_stall <= '1';
        co.b_stall <= '1';

        mwbo.adr<=(others => '0');
        mwbo.adr(ADDRESS_HIGH downto 2) <= r.fill_tag & r.fill_line_number & r.fill_offset_r;
        mwbo.cyc<='1';
        mwbo.stb<=not r.fill_r_done;
        mwbo.we<='0';

        if r.fill_is_b='1' then
          cmem_addrb <= r.fill_line_number & r.fill_offset_w;
          cmem_enb <= '1';
          cmem_ena <= '0';
          cmem_web <= (others => mwbi.ack);
          cmem_dib <= mwbi.dat;
        else
          cmem_addra <= r.fill_line_number & r.fill_offset_w;
          cmem_ena <= '1';
          cmem_enb <= '0';
          cmem_wea <= (others =>mwbi.ack);
          cmem_dia <= mwbi.dat;
        end if;

        if mwbi.stall='0' and r.fill_r_done='0' then
          w.fill_offset_r := std_logic_vector(unsigned(r.fill_offset_r) + 1);
          if r.fill_offset_r = offset_all_ones then
            w.fill_r_done := '1';
          end if;
        end if;

        if mwbi.ack='1' then
          w.fill_offset_w := std_logic_vector(unsigned(r.fill_offset_w) + 1);
          if r.fill_offset_w=offset_all_ones then
            w.state := settle;
            if r.fill_is_b='1' then
              tmem_addrb <= r.fill_line_number;
              tmem_dib(tag_type'RANGE) <= r.fill_tag;
              tmem_dib(VALID)<='1';
              tmem_dib(DIRTY)<=r.b_req_we;
              tmem_web<='1';
              tmem_enb<='1';
              if r.b_req_we='1' then
                -- Perform write
                w.state := write_after_fill;
              end if;
            else
              tmem_addra <= r.fill_line_number;
              tmem_dia(tag_type'RANGE) <= r.fill_tag;
              tmem_dia(VALID)<='1';
              tmem_dia(DIRTY)<='0';
              tmem_wea<='1';
              tmem_ena<='1';
            end if;
          end if;
        end if;


      when writeback =>

        co.a_stall <= '1';
        co.b_stall <= '1';
        w.rvalid := '1';

        mwbo.adr<=(others => '0');
        mwbo.adr(ADDRESS_HIGH downto 2) <= r.writeback_tag & r.fill_line_number & r.fill_offset_r;
        mwbo.cyc<=r.rvalid; --'1';
        mwbo.stb<=r.rvalid;--not r.fill_r_done;
        mwbo.we<=r.rvalid; --1';
        mwbo.sel<= (others => '1');
        if mwbi.stall='0' and r.rvalid='1'  then

          w.fill_offset_r := std_logic_vector(unsigned(r.fill_offset_r) + 1);
          if r.fill_offset_r = offset_all_ones then
            --w.fill_r_done := '1';
            w.fill_offset_r := (others => '0');
            w.fill_offset_w := (others => '0');
            w.fill_r_done := '0';
            if r.in_flush='1' then
              w.state := flush;
              w.in_flush:='0';
            else
              w.state := readline;
            end if;
          end if;
        end if;

        if (mwbi.stall='0' or r.rvalid='0') and r.fill_r_done='0' then
          w.fill_offset_w := std_logic_vector(unsigned(r.fill_offset_w) + 1);
          if r.fill_offset_w=offset_all_ones then
            --w.fill_offset_r := (others => '0');
            --w.fill_offset_w := (others => '0');
            w.fill_r_done := '1';

            --w.state := readline;
          end if;
        end if;

        if r.fill_is_b='1' then
          mwbo.dat <= cmem_dob;

          cmem_addrb <= r.fill_line_number & r.fill_offset_w;
          cmem_enb <= not mwbi.stall or not r.rvalid;
          cmem_ena <= '0';
          cmem_web <= (others=>'0');

        else
          mwbo.dat <= cmem_doa;
          cmem_addra <= r.fill_line_number & r.fill_offset_w;
          cmem_ena <= not mwbi.stall or not r.rvalid;
          cmem_enb <= '0';
          cmem_wea <= (others=>'0');
        end if;






      when write_after_fill =>
        --cmem_addra <= r.a_req_addr(CACHE_MAX_BITS-1 downto 2);
        cmem_addra <= (others => DontCareValue);
        cmem_addrb <= r.b_req_addr(CACHE_MAX_BITS-1 downto 2);
        cmem_dib <= r.b_req_data;
        cmem_web <= r.b_req_wmask;
        cmem_enb <= '1';

        co.a_stall <= '1';
        co.b_stall <= '1';
        co.a_valid <= '0'; -- ERROR
        co.b_valid <= '0'; -- ERROR
        w.ack_b_write := '1';
        w.state := settle;

      when settle =>
        cmem_addra <= r.a_req_addr(CACHE_MAX_BITS-1 downto 2);--r.fill_tag & r.fill_line_number & r.fill_offset_w;
        cmem_addrb <= r.b_req_addr(CACHE_MAX_BITS-1 downto 2);--r.fill_tag & r.fill_line_number & r.fill_offset_w;
        cmem_web <= (others => '0');
        tmem_addra <= address_to_line_number(r.a_req_addr);
        tmem_addrb <= address_to_line_number(r.b_req_addr);
        co.a_stall <= '1';
        co.b_stall <= '1';--not r.ack_b_write;--'1';

        co.a_valid <= '0'; -- ERROR
        co.b_valid <= '0';--r.ack_b_write; -- ERROR -- note: don't ack writes
        w.state := idle;

      when flush =>
        co.a_stall<='1';
        co.b_stall<='1';
        co.a_valid<='0';
        co.b_valid<='0';

        --tmem_addrb <= r.fill_line_number;
        tmem_addrb <= r.flush_line_number;
        tmem_addra <= (others => DontCareValue);
        tmem_ena <='0';
        tmem_wea <='0';

        tmem_dib(VALID)<='0';
        tmem_dib(DIRTY)<='0';

        tmem_web<='1';
        tmem_enb<='1';
        cmem_ena <= '0';
        cmem_enb <= '0';
        cmem_addra <= (others => DontCareValue);
        cmem_addrb <= (others => DontCareValue);
        cmem_dia <= (others => DontCareValue);
        cmem_dib <= (others => DontCareValue);
        --w.fill_line_number := r.fill_line_number+1;
        w.flush_line_number := r.flush_line_number+1;

        w.fill_offset_r := (others => '0');
        w.in_flush := '1';
        w.flush_req := '0';

        -- only valid in next cycle
        if r.in_flush='1' and tmem_dob(VALID)='1' and tmem_dob(DIRTY)='1' then
          report "Need to wb" severity note;
          w.writeback_tag := tmem_dob(tag_type'RANGE);
          w.fill_is_b := '1';
          tmem_web<='0';
          w.fill_offset_r := (others => '0');
          w.flush_line_number := r.flush_line_number;
          w.fill_r_done := '0';
          w.state := writeback;
        else
          w.fill_line_number := r.flush_line_number;

          if r.fill_line_number = line_number_all_ones then --r.in_flush='1' and r.fill_line_number=line_number_all_zeroes then
            w.state := idle;
            w.in_flush :='0';
          end if;
        end if;

    end case;

    if ci.flush='1' then
      w.flush_req :='1';
    end if;

    if rising_edge(syscon.clk) then
      if syscon.rst='1' then

        r.a_req <= '0';
        r.b_req <= '0';
        r.wr_conflict <= '0';
        r.misses<=0;
        r.flush_req<='0';
        r.in_flush<='0';
        --r.fill_line_number := (others => '0');
       -- r.flush_line_number := (others => '0');
        --r.state <= flush;
        r.state <= idle;
      else
        r <= w;
      end if;
    end if;

  end process;


end behave;