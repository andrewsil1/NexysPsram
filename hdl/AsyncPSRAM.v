`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date:    11:12:16 02/19/2012 
// Design Name: 
// Module Name:    AsyncPSRAM 
// Project Name: 
// Target Devices: 
// Tool versions: 
// Description: This module provides a simple interface to a common SRAM (static RAM) interface.
// In particular, it's designed for a 70ns Micron PSRAM part as included on the Digilent Nexys 2 and 3 dev boards.
// It will drive the 16-bit data bus based on the state of the Output Enable line with separate I/O/T channels for OBUFTs, and will also
// register the incoming value during a read which will remain persistently output until another read takes place.
// The inputs are self-describing. Wait until mem_idle is high, then setup the inputs and raise "go." When mem_idle
// goes low, you can de-assert go, and wait for the command to finish, signaled by mem_idle going high again. At that
// point it is safe to read data (if appropriate - The mem_data_rd is not affected during a write.)
//
// Dependencies: 
//
// Revision: 
// Revision 0.01 - File Created
// Additional Comments: 
//
/* +------------------------------------------------------------------------------------------------------------------------------+
   ¦                                                   TERMS OF USE: MIT License                                                  ¦                                                            
   +------------------------------------------------------------------------------------------------------------------------------¦
   ¦Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation    ¦ 
   ¦files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,    ¦
   ¦modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software¦
   ¦is furnished to do so, subject to the following conditions:                                                                   ¦
   ¦                                                                                                                              ¦
   ¦The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.¦
   ¦                                                                                                                              ¦
   ¦THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE          ¦
   ¦WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR         ¦
   ¦COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,   ¦
   ¦ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                         ¦
   +------------------------------------------------------------------------------------------------------------------------------+ 
   */
//////////////////////////////////////////////////////////////////////////////////
module AsyncPSRAM(
	input sysclk,
	input rst,
	input [15:0] mem_data_wr,
	input [22:0] mem_addr,
	input [1:0] mem_byte_en,
	input command,					// 0 = write, 1 = read
	input go,						// Signals that the command is ready to run.
	output reg mem_idle,			// 1 = unit is idle, ready for a command, 0 = busy.
	output reg [15:0] mem_data_rd, 	// Contains last read data.
	output reg [22:0] MEM_ADDR_OUT, // To PSRAM address bus
	output reg MEM_CEN,				// To PSRAM chip enable
	output reg MEM_OEN,				// To PSRAM output enable
	output reg MEM_WEN,				// To PSRAM write enable
	output reg MEM_LBN,				// To PSRAM low byte write enable
	output reg MEM_UBN,				// To PSRAM high byte write enable
	output reg MEM_ADV = 1'b0,    // To PSRAM address valid line
	output reg MEM_CRE,             // To PSRAM CRE line
	input [15:0] MEM_DATA_I,        // To PSRAM data bus
	output reg [15:0] MEM_DATA_O,   // To PSRAM data bus
	output [15:0] MEM_DATA_T        // To PSRAM data bus
    );

parameter MAX_CE_CYCLES = 379;      // Per datasheet, CE_N must go high every 4us for at least 15ns to allow mem refresh. (Use 380 to provide some margin.)
reg [8:0] ce_cycle_counter = 0;
reg [22:0] active_addr = 0;
reg [2:0] waitcount = 0;
reg [2:0] cycle_time = 0;
reg page_valid = 0;
reg cem_time_expired = 0;
reg [18:0] last_page_read = 0;

reg current_cmd;
reg cen_old;
wire reset_n;

// Bidirectional memory data bus
// Tri-state our output when OE is low, allowing incoming data to get to b and outp. Otherwise, drive the bus with A.
assign MEM_DATA_T = MEM_OEN ?  16'h0000 : 16'hFFFF;

//Invert reset logic.
assign reset_n = ~rst;

// These processes count active cycles of CEN and warns us when we get close to exceeding the max active time.
// The counter resets on falling transition of CEN but only counts when CEN is active.
always @ (posedge sysclk)
begin
    cen_old <= MEM_CEN;
end

always @ (posedge sysclk)  // When CE goes low for page reads, make sure it doesn't exceed Tcem (4 us) - trigger alarm if we get close.
begin   
    if (MEM_CEN == 0 && cen_old == 1) begin            // Reset counter on falling CEN edge.
        ce_cycle_counter <= 0;
        cem_time_expired <= 0;
    end else
    if (MEM_CEN == 0) begin                              // CE is low and we need to be counting.
        if (ce_cycle_counter == MAX_CE_CYCLES) begin
            cem_time_expired <= 1;                                   // Counter has run out and we should raise CEN again ASAP.
            ce_cycle_counter <= ce_cycle_counter;                    // Hold counter at present value.
        end else begin
            cem_time_expired <= 0;                                   // Page mode can continue.
            ce_cycle_counter <= ce_cycle_counter + 1;
        end
    end
end        

// Output write data to memory port
always @ (posedge sysclk)
begin
    MEM_DATA_O <= mem_data_wr;
end

parameter st_RESET 			= 	2'b01;
parameter st_COUNT		 	= 	2'b10;
parameter st_STARTPAGE      =   2'b11;
parameter st_DELAY          =   2'b00;
reg [1:0] state = 0;

always @(posedge sysclk) begin
	if (reset_n) begin
		state <= st_STARTPAGE;
		mem_idle <= 1'b1;
		mem_data_rd <= 0;
		current_cmd <= 1;
		page_valid <= 0;
		last_page_read <= 0;
		cycle_time <= 7;
		MEM_CEN <= 1'b1;
		MEM_OEN <= 1'b1;
		MEM_WEN <= 1'b1;
		MEM_ADDR_OUT <= 0;
		MEM_LBN <= 1;
		MEM_UBN <= 1;	
		MEM_CRE <= 1'b0;	
		end
	else
	case (state)
	    st_STARTPAGE: begin                 // Set PSRAM to page mode then wait for command completion, enter normal loop.
	       state <= st_COUNT;
	       MEM_CRE <= 1'b1;
	       MEM_ADDR_OUT <= 23'b00000000000000010010000; // Enable page mode
	       mem_idle <= 1'b0;
	       MEM_OEN <= 1'b1;
	       MEM_WEN <= 1'b0;
	       MEM_CEN <= 1'b0;
	       MEM_LBN <= 1'b0;
	       MEM_UBN <= 1'b0;
	       current_cmd <= 1'b0;
	       cycle_time <= 7;
	    end
	       
		st_RESET: begin						// Wait for incoming command.
			if (go) begin
			    if (page_valid == 0 || command == 0 || mem_addr[22:4] != last_page_read || cem_time_expired == 1) // We need to wait an extra cycle to allow CEM to be high long enough. 
				    state <= st_DELAY; 
				else
				    state <= st_COUNT; // Page read can begin right away.
				end
			else
				state <= st_RESET; // No command yet to act on.
			
			if (go) begin					// Got a command.
				MEM_ADDR_OUT <= mem_addr;	// Latch the address
				mem_idle <= 1'b0;			// Tell caller we're busy now.
				current_cmd <= command;		// Save current command for later.
				MEM_OEN <= ~command;		// Setup OEN/WEN based on the command.
				MEM_WEN <= command;
				MEM_LBN <= mem_byte_en[0];	// Set the write mask bits.
				MEM_UBN <= mem_byte_en[1];
				MEM_CRE <= 1'b0;
				if (page_valid == 1 && command == 1 && mem_addr[22:4] == last_page_read && cem_time_expired == 0) begin // We have a read command and the new address is in the same page and the refresh timer hasn't run out yet.
				    cycle_time <= 2; // In-Page reads take 20ns
				    MEM_CEN <= 1'b0; // CE remains low
				end else if (command == 0) begin
				    cycle_time <= 6; // On a write, cycle time is 6.
				    MEM_CEN <= 1'b1; // CE has to go high first.
				end else begin
				    cycle_time <= 7; // Else must be a read but not in the same page, or the refresh timer expired.  Need the full 70ns.
				    MEM_CEN <= 1'b1; // CE has to go high first.
				end 
			end
			else begin
				MEM_ADDR_OUT <= MEM_ADDR_OUT;	// No command yet, just wait.
				current_cmd <= 1'b1;
				mem_idle <= 1'b1;
				MEM_OEN <= 1'b1;
				MEM_WEN <= 1'b1;
				MEM_LBN <= 1;
				MEM_UBN <= 1;
				MEM_CRE <= 1'b0;
				cycle_time <= 6;
				if (MEM_CEN == 0 && cem_time_expired == 1) begin // If CEN is low and timer expires, we need to raise it. 
				    MEM_CEN <= 1;
				    page_valid <= 0;    // Once we raise CEN, we can't do a page read right away.
				end else begin
				    MEM_CEN <= MEM_CEN; // Hold CEN in present condition as long as the counter's ticking away.
				    page_valid <= page_valid;
				end
			end
		end
		
		st_DELAY: begin
		  state <= st_COUNT;
		  MEM_CEN <= 0;       // CE is ready to drop now.
		end
		
		st_COUNT: begin
			// If using a sysclk other than 100Mhz (10ns period) you must adjust the number of wait states accordingly below.
			if (waitcount == cycle_time) // If count 6 (during write) or (2 or) 7 (during (page) read), we're done after this cycle.
				state <= st_RESET;
			else
				state <= st_COUNT;

            page_valid <= current_cmd; // If this is a read command, then we could read from the same page next time if the new address is in the same page. 
            if (current_cmd == 1) 
                last_page_read <= MEM_ADDR_OUT[22:4]; // Save the upper bits that define the page. (Bottom four bits can change at will.)
            else 
                last_page_read <= 0;
            				
			if ((waitcount == cycle_time) && (current_cmd == 0)) begin	// This is a write command.  We bail out as soon as the 70ns is completed.
				MEM_OEN <= 1'b1;		// Positive strobe latches address and data in.
				MEM_WEN <= 1'b1;
				MEM_CEN <= 1'b1;        // CEN must go high again after a write.
				waitcount <= 0;
				mem_idle <= 1'b1;		// We'll be idle next cycle and ready for new commands.
				MEM_CRE <= 1'b0;
			end
			else if (waitcount == cycle_time) begin	// This is a read command.  We have to wait the previously calculated cycle time, and then latch in the incoming data.
				MEM_OEN <= 1'b1;			// Positive strobe latches address and data in.
				MEM_WEN <= 1'b1;
				MEM_CEN <= 1'b0;            // After a read we'll leave CEN low in case the next incoming command is a page read.
				waitcount <= 0;
				mem_idle <= 1'b1;
				MEM_CRE <= 1'b0;
				if (current_cmd == 1)
					mem_data_rd <= MEM_DATA_I;	// Grab read data on read cycles.
				else
					$display("Got to last waitstate without a read command! (Should never happen.)");
				end
			else							// We are still mid-wait.  Go another 10ns and reevaluate.
				waitcount <= waitcount + 1;
		end			
	endcase
end

endmodule
