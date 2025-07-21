`timescale 1ns/1ps
`include "./src/AXI_master.sv"
`include "./src/AXI_slave_skid.sv"
`include "./src/mem_simple.sv"
module master_slave_tb;

  parameter ID_WIDTH   = 1;
  parameter ADDR_WIDTH = 10;
  parameter DATA_WIDTH = 32;
  parameter LGMAXBURST = 2; // burst 0-3
  parameter LGFIFO     = LGMAXBURST + 1;
  parameter LGLEN      = ADDR_WIDTH;
  parameter STRB_WIDTH = DATA_WIDTH / 8;
  localparam ADDRLSB   = $clog2(DATA_WIDTH) - 3;
  localparam LGLENW    = LGLEN - ADDRLSB;

  logic ACLK;
  logic ARESETn;

  // Control
  logic                     w_start;
  logic [ADDR_WIDTH-1:0]    r_src_addr, r_dst_addr;
  logic [LGLEN-1:0]         r_len;
  logic                     success;
  // AXI signals
  // AXI Read Address Channel
  logic                     M_AXI_ARVALID;
  logic                     M_AXI_ARREADY;
  logic [ID_WIDTH-1:0]      M_AXI_ARID;
  logic [ADDR_WIDTH-1:0]    M_AXI_ARADDR;
  logic [7:0]               M_AXI_ARLEN;
  logic [2:0]               M_AXI_ARSIZE;
  logic [1:0]               M_AXI_ARBURST;

  // AXI Read Data Channel
  logic                     M_AXI_RVALID;
  logic                     M_AXI_RREADY;
  logic [ID_WIDTH-1:0]      M_AXI_RID;
  logic [DATA_WIDTH-1:0]    M_AXI_RDATA;
  logic                     M_AXI_RLAST;
  logic [1:0]               M_AXI_RRESP;

  // AXI Write Address Channel
  logic                     M_AXI_AWVALID;
  logic                     M_AXI_AWREADY;
  logic [ID_WIDTH-1:0]      M_AXI_AWID;
  logic [ADDR_WIDTH-1:0]    M_AXI_AWADDR;
  logic [7:0]               M_AXI_AWLEN;
  logic [2:0]               M_AXI_AWSIZE;
  logic [1:0]               M_AXI_AWBURST;

  // AXI Write Data Channel
  logic                     M_AXI_WVALID;
  logic                     M_AXI_WREADY;
  logic [DATA_WIDTH-1:0]    M_AXI_WDATA;
  logic [DATA_WIDTH/8-1:0]  M_AXI_WSTRB;
  logic                     M_AXI_WLAST;

  // AXI Write Response Channel
  logic                     M_AXI_BVALID;
  logic                     M_AXI_BREADY;
  logic [ID_WIDTH-1:0]      M_AXI_BID;
  logic [1:0]               M_AXI_BRESP;
  // Memory interface
  logic                      rd_src, we_init;
  logic [ADDR_WIDTH-ADDRLSB-1:0] addr_src, waddr_init;
  logic [DATA_WIDTH-1:0]     data_src, wdata_init;
  logic [STRB_WIDTH-1:0]     strb_dst, wstrb_init;
  // Memory interface
  logic                      we_dst;
  logic [ADDR_WIDTH-ADDRLSB-1:0] addr_dst;
  logic [DATA_WIDTH-1:0]     data_dst;
  logic [STRB_WIDTH-1:0]     strb_dst;
  // Clock generation
  initial ACLK = 0;
  always #5 ACLK = ~ACLK;

  // Reset
  initial begin
    ARESETn = 0;
    #50;
    ARESETn = 1;
  end

  // Instantiate your AXI Master
  axi_master #(
    .ID_WIDTH(ID_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .LGMAXBURST(LGMAXBURST),
    .LGFIFO(9),//to see continuous read/write
    .LGLEN(LGLEN)
  ) u_master (
    .ACLK, .ARESETn,
    .w_start, .r_src_addr, .r_dst_addr, .r_len,
    .M_AXI_ARVALID, .M_AXI_ARREADY,
    .M_AXI_ARID, .M_AXI_ARADDR, .M_AXI_ARLEN,
    .M_AXI_ARSIZE, .M_AXI_ARBURST,
    .M_AXI_RVALID, .M_AXI_RREADY,
    .M_AXI_RID, .M_AXI_RDATA, .M_AXI_RLAST, .M_AXI_RRESP,
    .M_AXI_AWVALID, .M_AXI_AWREADY,
    .M_AXI_AWID, .M_AXI_AWADDR, .M_AXI_AWLEN,
    .M_AXI_AWSIZE, .M_AXI_AWBURST,
    .M_AXI_WVALID, .M_AXI_WREADY,
    .M_AXI_WDATA, .M_AXI_WSTRB, .M_AXI_WLAST,
    .M_AXI_BVALID, .M_AXI_BREADY,
    .M_AXI_BID, .M_AXI_BRESP
  );

  //------------------------------
  // Instance of AXI Slave 0 (Read Source)
  //------------------------------
  axi_slave_skid #(
  .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
  .STRB_WIDTH(STRB_WIDTH), .ID_WIDTH(ID_WIDTH)
  ) slave_src (
  .ACLK(ACLK), .ARESETn(ARESETn),
  .S_AWID(), .S_AWADDR(), .S_AWLEN(),  // 不接 Write channel
  .S_AWSIZE(), .S_AWBURST(), .S_AWVALID(), .S_AWREADY(),
  .S_WDATA(), .S_WSTRB(), .S_WLAST(), .S_WVALID(), .S_WREADY(),
  .S_BID(), .S_BRESP(), .S_BVALID(), .S_BREADY(),
  .S_ARID(M_AXI_ARID), .S_ARADDR(M_AXI_ARADDR), .S_ARLEN(M_AXI_ARLEN),
  .S_ARSIZE(M_AXI_ARSIZE), .S_ARBURST(M_AXI_ARBURST), .S_ARVALID(M_AXI_ARVALID), .S_ARREADY(M_AXI_ARREADY),
  .S_RID(M_AXI_RID), .S_RDATA(M_AXI_RDATA), .S_RRESP(M_AXI_RRESP), .S_RLAST(M_AXI_RLAST),
  .S_RVALID(M_AXI_RVALID), .S_RREADY(M_AXI_RREADY),

  .o_we(), .o_waddr(), .o_wdata(), .o_wstrb(),
  .o_rd(rd_src), .o_raddr(addr_src), .i_rdata(data_src)
  );

  mem_simple #(
  .ADDR_WIDTH(ADDR_WIDTH - ADDRLSB), .DATA_WIDTH(DATA_WIDTH)
  ) mem_src (
  .clk(ACLK), .we(we_init), .waddr(waddr_init), .wdata(wdata_init), .wstrb(wstrb_init),
  .rd(rd_src), .raddr(addr_src), .rdata(data_src)
  );

  //------------------------------
  // Instance of AXI Slave 1 (Write Target)
  //------------------------------
  axi_slave_skid #(
  .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
  .STRB_WIDTH(STRB_WIDTH), .ID_WIDTH(ID_WIDTH)
  ) slave_dst (
  .ACLK(ACLK), .ARESETn(ARESETn),
  .S_AWID(M_AXI_AWID), .S_AWADDR(M_AXI_AWADDR), .S_AWLEN(M_AXI_AWLEN),
  .S_AWSIZE(M_AXI_AWSIZE), .S_AWBURST(M_AXI_AWBURST), .S_AWVALID(M_AXI_AWVALID), .S_AWREADY(M_AXI_AWREADY),
  .S_WDATA(M_AXI_WDATA), .S_WSTRB(M_AXI_WSTRB), .S_WLAST(M_AXI_WLAST), .S_WVALID(M_AXI_WVALID), .S_WREADY(M_AXI_WREADY),
  .S_BID(M_AXI_BID), .S_BRESP(M_AXI_BRESP), .S_BVALID(M_AXI_BVALID), .S_BREADY(M_AXI_BREADY),
  .S_ARID(), .S_ARADDR(), .S_ARLEN(), // 不接 Read channel
  .S_ARSIZE(), .S_ARBURST(), .S_ARVALID(), .S_ARREADY(),
  .S_RID(), .S_RDATA(), .S_RRESP(), .S_RLAST(),
  .S_RVALID(), .S_RREADY(),

  .o_we(we_dst), .o_waddr(addr_dst), .o_wdata(data_dst), .o_wstrb(strb_dst),
  .o_rd(), .o_raddr(), .i_rdata('0)
  );

  mem_simple #(
  .ADDR_WIDTH(ADDR_WIDTH - ADDRLSB), .DATA_WIDTH(DATA_WIDTH)
  ) mem_dst (
  .clk(ACLK), .we(we_dst), .waddr(addr_dst), .wdata(data_dst), .wstrb(strb_dst),
  .rd(1'b0), .raddr('0), .rdata()
  );

  initial begin
    $fsdbDumpfile("wave/tb_master_slave.fsdb");
    $fsdbDumpvars("+struct", "+mda", master_slave_tb);
    ARESETn = 0;
    #50;
    ARESETn = 1;
  end


  initial begin
    we_init     = 0;
    waddr_init  = 0;
    wdata_init  = 0;
    wstrb_init  = '1;

    @(posedge ARESETn);
    repeat (2) @(posedge ACLK);

    for (int i = 0; i < (1 << (ADDR_WIDTH - ADDRLSB)); i++) begin
      @(posedge ACLK);
      we_init     = 1;
      waddr_init  = i[ADDR_WIDTH - ADDRLSB - 1:0];
      wdata_init  = (i % 256) + 1;
      wstrb_init  = '1;
    end

    @(posedge ACLK);
    we_init = 0;
  end
  // Stimulus
  initial begin
    @(posedge ARESETn);
    repeat (5) @(posedge ACLK);

    r_src_addr <= 10'h000;
    r_dst_addr <= 10'h000;
    r_len      <= 10'd160; // 160 bytes = 10 burst， 4-beat (ARLEN=3)

    w_start    <= 1;
    @(posedge ACLK);
    w_start    <= 0;

    // Wait for master to finish
    repeat (500) @(posedge ACLK);

    //$finish;
  end
  
  initial begin
  wait (ARESETn);
  repeat (600) @(posedge ACLK); 
  success = 1; 

  $display("compare src and dst...");
  for (int i = 0; i < 40; i++) begin  // 40 words = 160 bytes
      if (master_slave_tb.mem_src.mem[i] !== master_slave_tb.mem_dst.mem[i]) begin
      $display("Mismatch at word %0d: src=%h, dst=%h", i, master_slave_tb.mem_src.mem[i], master_slave_tb.mem_dst.mem[i]);
      success = 0;
      end
  end
  if (success) begin
    $display("=========\nSimulation PASS!\n=========");
  end else begin
    $display("Simulation FAIL!");
  end
  $finish;
  end

endmodule
