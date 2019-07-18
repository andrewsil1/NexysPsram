This project contains the source code for an AXI4-compatible PSRAM controller, as implemented on the Digilent Nexys4 development board.

I decided to create this project after doing some experimentation with Vivado's built-in "AXI EMC" IP.  The EMC supports the PSRAM in
asynchronous mode, but it's somewhat difficult to use it to program the PSRAM into page mode, and once it is, it's not particularly well
optimized for that configuration, and some redundant reads are seen which waste cycles.  So I decided to create my own from scratch, which
is represented here, and was an excellent learning experience to become familiar with the semantics of the AXI4 bus.

The core could probably be optimized to squeeze out a few more cycles of overhead here and there between consecutive operations, but it's
been validated to run in a relatively reliable and stable fashion as it stands here.  I hope you find good use for it and makes your Nexys4
projects simpler.
-- Andy Silverman, 7/31/2014

Revision List:
7/17/2019: Was having trouble with System Cache again in Vivado 2019.1 (probably earlier as well), so recreated the AXI interface module
           using the latest AXI memory master sample IP in Vivado and the cache errors appear to have stopped. I didn't change any core
	   logic, but the latest VHDL uses the numeric std library instead of a different flavor, so perhaps there was some subtle difference.
9/2/2014:  Fixed a bug that could cause memory data corruption if a read and a write transaction were initiated in exactly the same 
           bus cycle. This was discovered when using the core in conjunction with the Xilinx System Cache IP rather than connecting
           it directly to the Microblaze DC and/or IC AXI buses.
8/3/2014:  Further validated with Xilinx AXI Protocol Checker and fixed an issue with RLAST generation.

Features:
- Created from the Xilinx Vivado 2014.2 AXI IP creation sample, and derived from their original block RAM implementation.
- The block RAM instantiation is replaced with original logic to call a new module of my own design to control the 16MB Micron PSRAM.
- The PSRAM runs in asynchronous page-read mode.  Use of page-read allows consecutive reads to take place in significantly
  less time on nearby addresses (i.e. 20ns per 16 bits for addresses in the same 16-word "page", rather than 70ns.)  Unfortunately, writes
  do not allow the same reduction in access time.
- The IP is optimized to recognize when memory accesses cross a page boundary and require a new 70ns access and CEN line toggle to continue
  valid operation. Similarly, the IP also recognizes when the CEN line has been low for a period of time approaching the Tcem limit of 4us
  documented in the datasheet and will automatically force CEN to cycle to permit memory refresh to operate normally without data corruption.
  Thus, operation with all the benefits of page-read mode is completely automatic without any intervention from the system designer.
- Compatible with AXI4 implementations where the AXI clock is 100Mhz and 32-bits wide.  Changing to a different AXI clock speed would require
  revision of the PSRAM logic to comply with the asynchronous timing requirements.
- Unaligned and/or narrow reads (e.g. 16 bit or 8 bit memory access) are somewhat optimized to avoid unnecessary memory operations
  accessing the not-requested half of the 32 bit DWORD when possible.
- Supports typical FIXED, INCR, and WRAP bus transactions.  Can be connected to Microblaze DC or IC cache interfaces for further performance enhancement.
- Validated to successfully pass all automatically generated Xilinx SDK memory tests with Microblaze caching of this memory region enabled and disabled.
  Some revisions to the sample's internal control logic were necessary because transactions to PSRAM do not complete in a single cycle as they 
  do with block RAM.

Restrictions:
- Compatible with AXI4 implementations where the AXI clock is 100Mhz and 32-bits wide.  Changing to a different AXI clock speed would require
  revision of the PSRAM logic to comply with the asynchronous timing requirements.  It also probably wouldn't be a huge amount of work to support
  a 64-bit wide AXI data bus, but it's not currently set up for that in all the places where it would need to be.
- Licensed under the terms of the included MIT License.  I hope you find it useful.