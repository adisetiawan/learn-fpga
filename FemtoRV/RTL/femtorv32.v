// femtorv32, a minimalistic RISC-V RV32I core 
//   (minus SYSTEM and FENCE that are not implemented)
// Bruno Levy, May-June 2020
//
// Mission statement:
//   - understand basics of FPGA and processor design
//   - learn about RISC-V
//   - create a RISC-V design that is easy to understand (and that
//       I'm able to re-read, re-understand later)
//   - create a RISC-V design that can be used on the cheapest /
//       smallest FPGAs (ICEStick) and that can be programmed in
//       assembly and C using the GNU RISC-V toolchain
//
//   Note: femtorv32 is meant to be used for educational purposes,
// targeting legibility of the design and minimal LUT footprint.
//  For other usages, if your FPGA has more than 1380 LUTs (that means,
// is something else than an ICEStick), I recommend using a more efficient /
// more complete RISC-V core (e.g., Claire Wolf's picorv32).
//
// Dhrystones and LUT-golfing par: see README.md


`ifdef VERBOSE
  `define verbose(command) command
`else
  `define verbose(command)
`endif

`ifdef BENCH
 `ifdef QUIET
  `define bench(command) 
 `else
  `define bench(command) command
 `endif
`else
  `define bench(command)
`endif

`include "register_file.v"
`include "small_alu.v"
`include "large_alu.v"
`include "branch_predicates.v"
`include "decoder.v"

/********************* Nrv processor *******************************/

module FemtoRV32 #(
  parameter [0:0] RV32M              = 0, // Set to 1 to support mul/div/rem instructions		   
  parameter       ADDR_WIDTH         = 16 // width of the address bus
) (
   input 	     clk,

   // Memory interface: using the same protocol as Claire Wolf's picoR32
   //                   (WIP: add mem_valid / mem_ready protocol)
   output [31:0]     mem_addr, // address bus, only ADDR_WIDTH bits are used
   output reg [31:0] mem_wdata, // data to be written
   output reg [3:0]  mem_wstrb, // write mask for individual bytes (1 means write byte)   
   input [31:0]      mem_rdata, // input lines for both data and instr
   output reg 	     mem_instr, // active when reading instruction (and not when reading data)
   
   input wire 	     reset, // set to 0 to reset the processor
   output wire 	     error      // 1 if current instruction could not be decoded
);

   // The states, using 1-hot encoding (reduces
   // both LUT count and critical path).
   
   localparam INITIAL              = 8'b00000000;   
   localparam WAIT_INSTR           = 8'b00000001;
   localparam FETCH_INSTR          = 8'b00000010;
   localparam USE_PREFETCHED_INSTR = 8'b00000100;
   localparam FETCH_REGS           = 8'b00001000;
   localparam EXECUTE              = 8'b00010000;
   localparam WAIT_ALU_OR_DATA     = 8'b00100000;
   localparam LOAD                 = 8'b01000000;
   localparam ERROR                = 8'b10000000;

   localparam WAIT_INSTR_bit           = 0;
   localparam FETCH_INSTR_bit          = 1;
   localparam USE_PREFETCHED_INSTR_bit = 2;
   localparam FETCH_REGS_bit           = 3;
   localparam EXECUTE_bit              = 4;
   localparam WAIT_ALU_OR_DATA_bit     = 5;
   localparam LOAD_bit                 = 6;   
   localparam ERROR_bit                = 7;
   
   reg [7:0] state = INITIAL;

   // The internal register that stores the current address,
   // directly wired to the address bus.
   reg [ADDR_WIDTH-1:0] addressReg;

   // The program counter.
   reg [ADDR_WIDTH-3:0] PC;

`ifdef NRV_COUNTERS
 `ifdef NRV_COUNTERS_64   
   reg [63:0] 		counter_cycle;
   reg [63:0] 		counter_instret;
 `else
   reg [31:0] 		counter_cycle;
   reg [31:0] 		counter_instret;
 `endif   
`endif
   
   assign mem_addr = addressReg;

   reg [31:0] instr;     // Latched instruction. 
   reg [31:0] nextInstr; // Prefetched instruction.

 
   // Next program counter in normal operation: advance one word
   // I do not use the ALU, I create an additional adder for that.
   wire [ADDR_WIDTH-3:0] PCplus4 = PC + 1;

   // Internal signals, all generated by the decoder from the current instruction.
   wire [4:0] 	 writeBackRegId; // The register to be written back
   wire 	 writeBackEn;    // Needs to be asserted for writing back
   wire [3:0]	 writeBackSel;   // 0001: ALU  0010: PC+4  0100: RAM  1000: counters
   wire [4:0] 	 regId1;         // Register output 1
   wire [4:0] 	 regId2;         // Register output 2
   wire 	 aluInSel1;      // 0: register  1: pc
   wire 	 aluInSel2;      // 0: register  1: imm
   wire 	 aluSel;         // 0: force aluOp,aluQual to zero (ADD)  1: use aluOp,aluQual from instr field
   wire [2:0] 	 aluOp;          // one of the 8 operations done by the ALU
   wire 	 aluQual;        // 'qualifier' used by some operations (+/-, logical/arith shifts)
   wire          aluM;           // asserted if instr is RV32M.
   wire [2:0] 	 nextPCSel;      // 001: PC+4  010: ALU  100: (predicate ? ALU : PC+4)
   wire [31:0] 	 imm;            // immediate value decoded from the instruction
   wire          needWaitALU;    // asserted if instruction uses at least one additional phase in ALU
   wire 	 isLoad;         // guess what, true if instr is a load
   wire 	 isStore;        // guess what, true if instr is a store
   wire          decoderError;   // true if instr does not correspond to any known instr

   // The instruction decoder, that reads the current instruction 
   // and generates all the signals from it. It is in fact just a
   // big combinatorial function.
   
   NrvDecoder decoder(
     .instr(instr),		     
     .writeBackRegId(writeBackRegId),
     .writeBackEn(writeBackEn),
     .writeBackSel(writeBackSel),
     .inRegId1(regId1),
     .inRegId2(regId2),
     .aluInSel1(aluInSel1), 
     .aluInSel2(aluInSel2),
     .aluSel(aluSel),		     
     .aluOp(aluOp),
     .aluQual(aluQual),
     .aluM(aluM),		      
     .needWaitALU(needWaitALU),		      
     .isLoad(isLoad),
     .isStore(isStore),
     .nextPCSel(nextPCSel),
     .imm(imm),
     .error(decoderError)     		     
   );

   // Maybe not necessary, but I'd rather latch this one,
   // if this one glitches, then it will break everything...
   reg error_latched;
   assign error = error_latched;
   
   wire [31:0] aluOut;
   wire        aluBusy;
   wire	       writeBack = (state[EXECUTE_bit] && writeBackEn) || state[WAIT_ALU_OR_DATA_bit];
   
   // The register file. At each cycle, it can read two
   // registers (available at next cycle) and write one.
   reg  [31:0] writeBackData;
   wire [31:0] regOut1;
   wire [31:0] regOut2;   
   NrvRegisterFile regs(
    .clk(clk),
    .in(writeBackData),
    .inEn(writeBack),
    .inRegId(writeBackRegId),		       
    .outRegId1(regId1),
    .outRegId2(regId2),
    .out1(regOut1),
    .out2(regOut2) 
   );

   // The ALU, partly combinatorial, partly state (for shifts).
   wire [31:0] aluIn1 = aluInSel1 ? {PC, 2'b00} : regOut1;
   wire [31:0] aluIn2 = aluInSel2 ? imm : regOut2;
   
   generate
      if(RV32M) begin
         NrvLargeALU alu(
            .clk(clk),	      
            .in1(aluIn1),
            .in2(aluIn2),
            .op(aluOp & {3{aluSel}}),
            .opqual(aluQual & aluSel),
            .opM(aluM),	 
            .out(aluOut),
            .wr(state == EXECUTE), 
            .busy(aluBusy)	      
         );
      end else begin 
         NrvSmallALU #(
`ifdef NRV_TWOSTAGE_SHIFTER	      
          .TWOSTAGE_SHIFTER(1),
`else
          .TWOSTAGE_SHIFTER(0),	      
`endif
         ) alu(
            .clk(clk),	      
            .in1(aluIn1),
            .in2(aluIn2),
            .op(aluOp & {3{aluSel}}),
            .opqual(aluQual & aluSel),
            .out(aluOut),
            .wr(state == EXECUTE), 
            .busy(aluBusy)	      
         );
      end
   endgenerate
      
   // LOAD: decode datain based on type and address
   
   reg [31:0] decodedDataIn;   
   reg [15:0]  mem_rdata_H;
   reg [7:0]   mem_rdata_B;

   always @(*) begin
      (* parallel_case, full_case *)            
      case(mem_addr[1])
	1'b0: mem_rdata_H = mem_rdata[15:0];
	1'b1: mem_rdata_H = mem_rdata[31:16];
      endcase 
      
      (* parallel_case, full_case *)            
      case(mem_addr[1:0])
	2'b00: mem_rdata_B = mem_rdata[7:0];
	2'b01: mem_rdata_B = mem_rdata[15:8];
	2'b10: mem_rdata_B = mem_rdata[23:16];
	2'b11: mem_rdata_B = mem_rdata[31:24];
      endcase 

      // aluop[1:0] contains data size (00: byte, 01: half word, 10: word)
      // aluop[2] sign expansion toggle (0 = sign expansion, 1 = no sign expansion)
      (* parallel_case, full_case *)      
      case(aluOp[1:0])
	2'b00: decodedDataIn = {{24{aluOp[2]?1'b0:mem_rdata_B[7]}},mem_rdata_B};
	2'b01: decodedDataIn = {{16{aluOp[2]?1'b0:mem_rdata_H[15]}},mem_rdata_H};
	default: decodedDataIn = mem_rdata;
      endcase
   end

`ifdef NRV_COUNTERS
   reg [31:0] counter;
   always @(*) begin
      (* parallel_case, full_case *)      
      case(instr[31:20])
	12'b110000000000: counter = counter_cycle[31:0];    // CYCLE
	12'b110000000001: counter = counter_cycle[31:0];    // TIME
	12'b110000000010: counter = counter_instret[31:0];  // INSTRET
 `ifdef NRV_COUNTERS_64
	12'b110010000000: counter = counter_cycle[63:32];   // CYCLEH
	12'b110010000001: counter = counter_cycle[63:32];   // TIMEH
	12'b110010000010: counter = counter_instret[63:32]; // INSTRETH
 `endif
	default: counter = {32{1'bx}};
      endcase 
   end
`endif   
   
   // The value written back to the register file.
   always @(*) begin
      (* parallel_case, full_case *)
      case(1'b1)
	writeBackSel[0]: writeBackData = aluOut;
	writeBackSel[1]: writeBackData = {PCplus4, 2'b00};
	writeBackSel[2]: writeBackData = decodedDataIn;
`ifdef NRV_COUNTERS
	writeBackSel[3]: writeBackData = counter;	
`endif
      endcase
   end

   // The predicate for conditional branches. 
   wire predOut;
   NrvPredicate pred(
    .in1(regOut1),
    .in2(regOut2),
    .op(aluOp),
    .out(predOut)		    
   );

`ifdef NRV_COUNTERS
   always @(posedge clk) begin
      if(!reset) begin	    
	 counter_instret <= 0;
	 counter_cycle   <= 0;
      end else begin
	 counter_cycle <= counter_cycle+1;
	 if(state[FETCH_REGS_bit]) begin
	    counter_instret <= counter_instret+1;
	 end
      end
   end
`endif
   
   always @(posedge clk) begin
      `verbose($display("state = %h",state));
      if(!reset) begin
	 state <= INITIAL;
	 mem_instr <= 1'b1;
	 mem_wstrb <= 4'b0000;
	 addressReg <= 0;
	 PC <= 0;
      end else
      case(1'b1)
	(state == 0): begin
	   `verbose($display("INITIAL"));
	   state <= WAIT_INSTR;
	end
	state[WAIT_INSTR_bit]: begin
	   // this state to give enough time to fetch the 
	   // instruction. Used for jumps and taken branches (and 
	   // when fetching the first instruction). 
	   `verbose($display("WAIT_INSTR"));
	   state <= FETCH_INSTR;
	end
	state[FETCH_INSTR_bit]: begin
	   `verbose($display("FETCH_INSTR"));	   
	   instr <= mem_rdata;
	   // update instr address so that next instr is fetched during
	   // decode (and ready if there was no jump or branch)
	   addressReg <= {PCplus4, 2'b00}; 
	   state <= FETCH_REGS;
	end
	state[USE_PREFETCHED_INSTR_bit]: begin
	   `verbose($display("USE_PREFETCHED_INSTR"));	   
	   instr <= nextInstr;
	   // update instr address so that next instr is fetched during
	   // decode (and ready if there was no jump or branch)
	   addressReg <= {PCplus4, 2'b00}; 
	   state <= FETCH_REGS;
	   mem_wstrb <= 4'b0000;
	end
	state[FETCH_REGS_bit]: begin
	   // instr was just updated -> input register ids also
	   // input registers available at next cycle 
	   state <= EXECUTE;
	   error_latched <= decoderError;
	end
	state[EXECUTE_bit]: begin
	   // input registers are read, aluOut is up to date
	   
	   // Lookahead instr.
	   nextInstr <= mem_rdata;

	   // Needed for LOAD,STORE,jump,branch
	   // (in other cases it will be ignored)
	   addressReg <= aluOut; 
	   
	   if(error_latched) begin
	      state <= ERROR;
	   end else if(isLoad) begin
	      state <= LOAD;
	      PC <= PCplus4;
	      mem_instr <= 1'b0;
	   end else if(isStore) begin
	      state <= USE_PREFETCHED_INSTR; // Data will be written in USE_PREFETCHED_INSTR
	      PC <= PCplus4;
	      case(aluOp[1:0])
		2'b00: begin
		   case(aluOut[1:0]) // Address is now in aluOut (and not in mem_address yet !!)
		     2'b00: begin
			mem_wstrb <= 4'b0001;
			mem_wdata <= {24'bxxxxxxxxxxxxxxxxxxxxxxxx,regOut2[7:0]};
		     end
		     2'b01: begin
			mem_wstrb <= 4'b0010;
			mem_wdata <= {16'bxxxxxxxxxxxxxxxx,regOut2[7:0],8'bxxxxxxxx};
		     end
		     2'b10: begin
			mem_wstrb <= 4'b0100;
			mem_wdata <= {8'bxxxxxxxx,regOut2[7:0],16'bxxxxxxxxxxxxxxxx};
		     end
		     2'b11: begin
			mem_wstrb <= 4'b1000;
			mem_wdata <= {regOut2[7:0],24'bxxxxxxxxxxxxxxxxxxxxxxxx};
		     end
		   endcase
		end
		2'b01: begin
		   case(aluOut[1]) // Address is now in aluOut (and not in mem_address yet !!)
		     1'b0: begin
			mem_wstrb <= 4'b0011;
			mem_wdata <= {16'bxxxxxxxxxxxxxxxx,regOut2[15:0]};
		     end
		     1'b1: begin
			mem_wstrb <= 4'b1100;
			mem_wdata <= {regOut2[15:0],16'bxxxxxxxxxxxxxxxx};
		     end
		   endcase
		end
		2'b10: begin
		   mem_wstrb <= 4'b1111;
		   mem_wdata <= regOut2;
		end
		default: begin
		   mem_wstrb <= 4'bxxxx;
		   mem_wdata <= 32'bxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx;
		end
	      endcase 
	   end else begin 
	      (* parallel_case, full_case *)
	      case(1'b1)
		nextPCSel[0]: begin // normal operation
		   PC <= PCplus4;
		   state <= needWaitALU ? WAIT_ALU_OR_DATA : USE_PREFETCHED_INSTR;
		end		   
		nextPCSel[1]: begin // unconditional jump (JAL, JALR)
		   PC <= aluOut[31:2];
		   state <= WAIT_INSTR;
		end
		nextPCSel[2]: begin // branch
		   if(predOut) begin
		      PC <= aluOut[31:2];
		      state <= WAIT_INSTR;
		   end else begin
		      PC <= PCplus4;
		      state <= USE_PREFETCHED_INSTR;
		   end
		end
	      endcase 
	   end 
	end
	state[LOAD_bit]: begin
	   `verbose($display("LOAD"));
	   // data address (aluOut) was just updated
	   // data ready at next cycle
	   // we go to WAIT_ALU_OR_DATA to write back read data
	   state <= WAIT_ALU_OR_DATA;
	   mem_instr <= 1'b1;
	end
	state[WAIT_ALU_OR_DATA_bit]: begin
	   `verbose($display("WAIT_ALU_OR_DATA"));	   
	   // - If ALU is still busy, continue to wait.
	   // - register writeback is active
	   state <= aluBusy ? WAIT_ALU_OR_DATA : USE_PREFETCHED_INSTR;
	end
	state[ERROR_bit]: begin
	   `bench($display("ERROR"));
           state <= ERROR;
	end
	default: begin
	   `bench($display("UNKNOWN STATE"));	   	   	   
	   state <= ERROR;
	end
      endcase
  end   
   
endmodule
