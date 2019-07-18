----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date:    11:12:16 02/19/2012 
-- Design Name: 
-- Module Name:    AsyncPSRAM 
-- Project Name: 
-- Target Devices: 
-- Tool versions: 
-- Description: This module provides a simple interface to a common SRAM (static RAM) interface.
-- In particular, it's designed for a 70ns Micron PSRAM part as included on the Digilent Nexys 2 and 3 dev boards.
-- It will drive the 16-bit data bus based on the state of the Output Enable line with separate I/O/T channels for OBUFTs, and will also
-- register the incoming value during a read which will remain persistently output until another read takes place.
-- The inputs are self-describing. Wait until mem_idle is high, then setup the inputs and raise "go." When mem_idle
-- goes low, you can de-assert go, and wait for the command to finish, signaled by mem_idle going high again. At that
-- point it is safe to read data (if appropriate - The mem_data_rd is not affected during a write.)
--
-- Dependencies: 
--
-- Revision: 
-- Revision 0.01 - File Created
-- Additional Comments: 
--
-- +------------------------------------------------------------------------------------------------------------------------------+
   -- ¦                                                   TERMS OF USE: MIT License                                               ¦                                                               -- +------------------------------------------------------------------------------------------------------------------------------¦
   -- ¦Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation ¦ 
   -- ¦files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, ¦
   -- ¦modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software¦
   -- ¦is furnished to do so, subject to the following conditions:                                                                ¦
   -- ¦                                                                                                                           ¦
   -- ¦The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.¦
   -- ¦                                                                                                                           ¦
   -- ¦THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE       ¦
   -- ¦WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR      ¦
   -- ¦COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,¦
   -- ¦ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                      ¦
   -- +---------------------------------------------------------------------------------------------------------------------------+ 
   -- 
   
 library ieee;
   use ieee.std_logic_1164.all;
   use ieee.std_logic_arith.all;
   use ieee.std_logic_unsigned.all;
   
 entity AsyncPSRAM is
	port (
		sysclk 				: in std_logic;
		rst					: in std_logic;
		mem_data_wr			: in std_logic_vector(15 downto 0);
		mem_addr			: in std_logic_vector(22 downto 0); 
		mem_byte_en			: in std_logic_vector(1 downto 0); 
		command				: in std_logic;
		go					: in std_logic;
		mem_idle			: out std_logic;
		mem_data_rd			: out std_logic_vector(15 downto 0);
		MEM_ADDR_OUT		: out std_logic_vector(22 downto 0);
		MEM_CEN				: out std_logic;
		MEM_OEN				: out std_logic;
		MEM_WEN				: out std_logic;
		MEM_LBN				: out std_logic;
		MEM_UBN				: out std_logic;
		MEM_ADV 			: out std_logic := '0';
		MEM_CRE				: out std_logic;
		MEM_DATA_I			: in std_logic_vector(15 downto 0);
		MEM_DATA_O			: out std_logic_vector(15 downto 0);
		MEM_DATA_T        	: out std_logic_vector(15 downto 0)
    );
end AsyncPSRAM;

architecture functional of AsyncPSRAM is

	constant MAX_CE_CYCLES 		: integer range 0 to 511 := 379;
	signal	ce_cycle_counter 	: integer range 0 to 511 := 0;
	signal	active_addr 		: std_logic_vector(22 downto 0) := "00000000000000000000000";
	signal	waitcount			: integer range 0 to 127 := 0;
	signal	cycle_time			: integer range 0 to 127 := 0;
	signal	page_valid			: std_logic := '0';
	signal	cem_time_expired	: std_logic := '0';
	signal	last_page_read		: std_logic_vector(18 downto 0) := "0000000000000000000";
	signal	current_cmd			: std_logic := '1';
	signal	cen_old				: std_logic;
	signal	reset_p				: std_logic;
	signal  mem_oen_i           : std_logic;
	signal  mem_cen_i           : std_logic;
	signal  mem_addr_out_i      : std_logic_vector(22 downto 0);
	signal  mem_data_rd_i       : std_logic_vector(15 downto 0);
	
	type stateType is (st_RESET, st_COUNT, st_STARTPAGE, st_DELAY);
    signal state : stateType;

begin
    
    mem_data_rd <= mem_data_rd_i;
    mem_addr_out <= mem_addr_out_i;
    MEM_OEN <= mem_oen_i;
    MEM_CEN <= mem_cen_i;
    MEM_DATA_T <= x"0000" when mem_oen_i = '1' else
                  x"FFFF" when mem_oen_i = '0';
                  
    reset_p <= not rst;
    
    --Output write data to memory port
    process(sysclk)
    begin
        if (rising_edge(sysclk)) then
            MEM_DATA_O <= mem_data_wr;
        end if;
    end process;
    
    --Track last state of CEN to catch changes in state.
    process(sysclk)
    begin
        if (rising_edge(sysclk)) then
            cen_old <= mem_cen_i;
        end if;
    end process;
    
    process(sysclk)
    begin
        if (rising_edge(sysclk)) then                   -- When CE goes low for page reads, make sure it doesn't exceed Tcem (4 us) - trigger alarm if we get close.   
            if (mem_cen_i = '0' and cen_old = '1') then   -- Reset counter on falling CEN edge.
                ce_cycle_counter <= 0;
                cem_time_expired <= '0';
            elsif (mem_cen_i = '0') then                  --CE is low and we need to be counting.
                if (ce_cycle_counter = MAX_CE_CYCLES) then
                    cem_time_expired <= '1';                                 -- Counter has run out and we should raise CEN again ASAP.
                    ce_cycle_counter <= ce_cycle_counter;                    -- Hold counter at present value.
                else
                    cem_time_expired <= '0';                                 -- Page mode can continue.
                    ce_cycle_counter <= ce_cycle_counter + 1;
                end if;
            end if;
        end if;
    end process; 
    
    process(sysclk) -- State Machine
    begin
        if (rising_edge(sysclk)) then
            if (reset_p = '1') then
                state <= st_STARTPAGE;
                mem_idle <= '1';
                mem_data_rd_i <= x"0000";
                current_cmd <= '1';
                page_valid <= '0';
                last_page_read <= (others => '0');
                cycle_time <= 7;
                mem_cen_i <= '1';
                mem_oen_i <= '1';
                MEM_WEN <= '1';
                mem_addr_out_i <= (others => '0');
                MEM_LBN <= '1';
                MEM_UBN <= '1';    
                MEM_CRE <= '0';
             else
                case (state) is
                    when st_STARTPAGE =>
                        state <= st_COUNT;
                        MEM_CRE <= '1';
                        mem_addr_out_i <= "00000000000000010010000"; -- Enable page mode
                        mem_idle <= '0';
                        mem_oen_i <= '1';
                        MEM_WEN <= '0';
                        mem_cen_i <= '0';
                        MEM_LBN <= '0';
                        MEM_UBN <= '0';
                        current_cmd <= '0';
                        cycle_time <= 7;
                    when st_RESET =>
                        if go = '1' then
                            mem_addr_out_i <= mem_addr;	-- Latch the address
                            mem_idle <= '0';            -- Tell caller we're busy now.
                            current_cmd <= command;     -- Save current command for later.
                            mem_oen_i <= not command;     -- Setup OEN/WEN based on the command.
                            MEM_WEN <= command;
                            MEM_LBN <= mem_byte_en(0);  -- Set the write mask bits.
                            MEM_UBN <= mem_byte_en(1);
                            MEM_CRE <= '0';
                            
                            if (page_valid = '1' and command = '1' and mem_addr(22 downto 4) = last_page_read and cem_time_expired = '0') then -- We have a read command and the new address is in the same page and the refresh timer hasn't run out yet.
                                cycle_time <= 2; -- In-Page reads take 20ns
                                mem_cen_i <= '0'; -- CE remains low
                            elsif (command = '0') then 
                                cycle_time <= 6; -- On a write, cycle time is 6.
                                mem_cen_i <= '1';  -- CE has to go high first.
                            else 
                                cycle_time <= 7; -- Else must be a read but not in the same page, or the refresh timer expired.  Need the full 70ns.
                                mem_cen_i <= '1';  -- CE has to go high first.
                            end if;
                            
                           if (page_valid = '0' or command = '0' or mem_addr(22 downto 4) /= last_page_read or cem_time_expired = '1') then -- We need to wait an extra cycle to allow CEM to be high long enough. 
                             state <= st_DELAY; 
                           else
                             state <= st_COUNT; -- Page read can begin right away.
                           end if;
                        else
                          state <= st_RESET; -- No command yet to act on.
                          mem_addr_out_i <= mem_addr_out_i;	-- No command yet, just wait.
                          current_cmd <= '1';
                          mem_idle <= '1';
                          mem_oen_i <= '1';
                          MEM_WEN <= '1';
                          MEM_LBN <= '1';
                          MEM_UBN <= '1';
                          MEM_CRE <= '0';
                          cycle_time <= 6;
                          if (mem_cen_i = '0' and cem_time_expired = '1') then  -- If CEN is low and timer expires, we need to raise it. 
                              mem_cen_i <= '1';
                              page_valid <= '0';    -- Once we raise CEN, we can't do a page read right away.
                          else 
                              mem_cen_i <= mem_cen_i; -- Hold CEN in present condition as long as the counter's ticking away.
                              page_valid <= page_valid;
                          end if;
                        end if;
            when st_DELAY =>
                state <= st_COUNT;
                mem_cen_i <= '0'; -- CE is ready to drop now.
            when st_COUNT =>
            -- If using a sysclk other than 100Mhz (10ns period) you must adjust the number of wait states accordingly below.
                if (waitcount = cycle_time) then -- If count 6 (during write) or (2 or) 7 (during (page) read), we're done after this cycle.
                    state <= st_RESET;
                else
                    state <= st_COUNT;
                end if;

                page_valid <= current_cmd; -- If this is a read command, then we could read from the same page next time if the new address is in the same page. 
                if (current_cmd = '1') then 
                    last_page_read <= mem_addr_out_i(22 downto 4); -- Save the upper bits that define the page. (Bottom four bits can change at will.)
                else 
                    last_page_read <= (others => '0');
                end if;
                                        
                if ((waitcount = cycle_time) and (current_cmd = '0')) then -- This is a write command.  We bail out as soon as the 70ns is completed.
                    mem_oen_i <= '1';        -- Positive strobe latches address and data in.
                    MEM_WEN <= '1';
                    mem_cen_i <= '1';        -- CEN must go high again after a write.
                    waitcount <= 0;
                    mem_idle <= '1';        -- We'll be idle next cycle and ready for new commands.
                    MEM_CRE <= '0';
                elsif (waitcount = cycle_time) then  -- This is a read command.  We have to wait the previously calculated cycle time, and then latch in the incoming data.
                    mem_oen_i <= '1';            -- Positive strobe latches address and data in.
                    MEM_WEN <= '1';
                    mem_cen_i <= '0';            -- After a read we'll leave CEN low in case the next incoming command is a page read.
                    waitcount <= 0;
                    mem_idle <= '1';
                    MEM_CRE <= '0';
                    if (current_cmd = '1') then
                        mem_data_rd_i <= MEM_DATA_I;    -- Grab read data on read cycles.
                    end if;
                else                            -- We are still mid-wait.  Go another 10ns and reevaluate.
                    waitcount <= waitcount + 1;
                end if;            
            end case;
         end if;
      end if;
   end process;
   
end functional;