`include "./src/skid_buffer.sv"
`include "./src/axi_addr.sv"
module axi_slave_skid #(
    parameter ADDR_WIDTH = 10,
    parameter DATA_WIDTH = 32,
    parameter STRB_WIDTH = DATA_WIDTH / 8,
    parameter ID_WIDTH   = 2,
    localparam LSB = $clog2(DATA_WIDTH)-3
)(
	//mem
	output	logic					    o_we,
	output	logic [ADDR_WIDTH-LSB-1:0]  o_waddr,
	output	logic [DATA_WIDTH-1:0]	    o_wdata,
	output	logic [STRB_WIDTH-1:0]	    o_wstrb,
	
	output	logic					    o_rd,
	output	logic [ADDR_WIDTH-LSB-1:0]  o_raddr,
	input	      [DATA_WIDTH-1:0]	    i_rdata,

    input                         ACLK,
    input                         ARESETn,

    // Write Address
    input      [ID_WIDTH-1:0]     S_AWID,
    input      [ADDR_WIDTH-1:0]   S_AWADDR,
    input      [7:0]              S_AWLEN,
    input      [2:0]              S_AWSIZE,
    input      [1:0]              S_AWBURST,
	input						  S_AWLOCK,
	input	   [3:0]              S_AWCACHE,
	input 	   [2:0]              S_AWPROT,	
	input      [3:0]              S_AWQOS, 
    input                         S_AWVALID,
    output logic                  S_AWREADY,

    // Write Data
    input      [DATA_WIDTH-1:0]   S_WDATA,
    input      [STRB_WIDTH-1:0]   S_WSTRB,
    input                         S_WLAST,
    input                         S_WVALID,
    output logic                  S_WREADY,

    // Write Response
    output logic [ID_WIDTH-1:0]   S_BID,
    output logic [1:0]            S_BRESP,
    output logic                  S_BVALID,
    input                         S_BREADY,

    // Read Address
    input      [ID_WIDTH-1:0]     S_ARID,
    input      [ADDR_WIDTH-1:0]   S_ARADDR,
    input      [7:0]              S_ARLEN,
    input      [2:0]              S_ARSIZE,
    input      [1:0]              S_ARBURST,
	input                         S_ARLOCK,
	input      [3:0]              S_ARCACHE,
	input      [2:0]              S_ARPROT,
	input      [3:0]              S_ARQOS,
    input                         S_ARVALID,
    output logic                  S_ARREADY,

    // Read Data
    output logic [ID_WIDTH-1:0]   S_RID,
    output logic [DATA_WIDTH-1:0] S_RDATA,
    output logic [1:0]            S_RRESP,
    output logic                  S_RLAST,
    output logic                  S_RVALID,
    input                         S_RREADY
);


	//skid buffer
	logic [ADDR_WIDTH-1:0] awaddr_buf;
	logic [7:0]  awlen_buf;
	logic [ID_WIDTH-1:0]   awid_buf;
	logic                  awvalid_buf, awready_buf, awlock_buf;
	logic      [2:0]       awsize_buf;
	logic      [1:0]       awburst_buf;

	// Double buffer the write response channel only
	logic	[ID_WIDTH-1 : 0]	r_bid;
	logic			r_bvalid;
	logic	[ID_WIDTH-1 : 0]	axi_bid;
	logic			axi_bvalid;
	logic			axi_awready, axi_wready;
	
	logic	[ADDR_WIDTH-1:0]	waddr;
	logic	[ADDR_WIDTH-1:0]	next_wr_addr;
	logic	[7:0]		wlen;
	logic	[2:0]		wsize;
	logic	[1:0]		wburst;
	logic	[ADDR_WIDTH-1:0]	next_rd_addr;


	logic	[7:0]		rlen;
	logic	[2:0]		rsize;
	logic	[1:0]		rburst;
	logic	[ID_WIDTH-1:0]	rid;
	logic			rlock;
	logic			axi_arready;
    logic	[8:0]		axi_rlen;
	logic	[ADDR_WIDTH-1:0]	raddr;

	// Read skid buffer
	logic			rskd_valid, rskd_last, rskd_lock;
	logic			rskd_ready;
	logic	[ID_WIDTH-1:0]	rskd_id;
	


	// AW Skid buffer
	skid_buffer #(.DWIDTH(ADDR_WIDTH + ID_WIDTH + 5 + 8 + 1)) aw_skid (
	.clk     (ACLK),
	.rstn    (ARESETn),
	.i_data  ({S_AWID, S_AWLEN, S_AWADDR, S_AWBURST, S_AWSIZE, S_AWLOCK}),
	.i_valid (S_AWVALID),
	.o_ready (S_AWREADY),
	.o_data  ({awid_buf, awlen_buf, awaddr_buf, awburst_buf, awsize_buf, awlock_buf}),
	.o_valid (awvalid_buf),
	.i_ready (awready_buf)
	);

	////////////////////////////////////////////////////////////////////////
	// Write
	////////////////////////////////////////////////////////////////////////

	always_ff @(posedge ACLK)
	if (!ARESETn)
	begin
		axi_awready  <= 1;
		axi_wready   <= 0;
	end else if (awvalid_buf && awready_buf)
	begin
		axi_awready <= 0;
		axi_wready  <= 1;
	end else if (S_WVALID && S_WREADY)
	begin
		axi_awready <= (S_WLAST)&&(!S_BVALID || S_BREADY);
		axi_wready  <= (!S_WLAST);
	end else if (!axi_awready)
	begin
		if (S_WREADY) begin
			axi_awready <= 1'b0;
		end else if (r_bvalid && !S_BREADY) begin
			axi_awready <= 1'b0;
		end else begin
			axi_awready <= 1'b1;
		end
	end

	// Next write address calculation
	// {{{
	always_ff @(posedge ACLK)
	if (awready_buf)
	begin
		waddr    <= awaddr_buf;
		wburst   <= awburst_buf;
		wsize    <= awsize_buf;
		wlen     <= awlen_buf;
	end else if (S_WVALID)
		waddr <= next_wr_addr;

	axi_addr #(
		// {{{
		.AW(ADDR_WIDTH), .DW(DATA_WIDTH)
		// }}}
	) get_next_wr_addr(
		// {{{
		waddr, wsize, wburst, wlen,
			next_wr_addr
		// }}}
	);
	// }}}

	// o_w*
	// {{{
	always_ff @(posedge ACLK) begin
		if (!ARESETn) begin
			o_we    <= 0;
			o_waddr <= 0;
			o_wdata <= 0;
			o_wstrb <= 0;
		end else begin
			o_we    <= (S_WVALID && S_WREADY);
			o_waddr <= waddr[ADDR_WIDTH-1:LSB];
			o_wdata <= S_WDATA;
			o_wstrb <= S_WSTRB;
		end
	end

	// Write return path
	// r_bvalid
	always_ff@(posedge ACLK)
	if (!ARESETn)
		r_bvalid <= 1'b0;
	else if (S_WVALID && S_WREADY && S_WLAST
			&&(S_BVALID && !S_BREADY))
		r_bvalid <= 1'b1;
	else if (S_BREADY)
		r_bvalid <= 1'b0;


	// r_bid, axi_bid
	// {{{
	always_ff@(posedge ACLK)
	if (!ARESETn)
	begin
		r_bid  <= 0;
		axi_bid <= 0;
    end else if (awready_buf) begin
		r_bid    <= awid_buf;
    end else if (!S_BVALID || S_BREADY) begin
		axi_bid <= r_bid;
	end
  
	// axi_bvalid

	always_ff@(posedge ACLK)
	if (!ARESETn)
		axi_bvalid <= 0;
	else if (S_WVALID && S_WREADY && S_WLAST)
		axi_bvalid <= 1;
	else if (S_BREADY)
		axi_bvalid <= r_bvalid;


	// m_awready
	always_comb
	begin
		awready_buf = axi_awready;
		if (S_WVALID && S_WREADY && S_WLAST
			&& (!S_BVALID || S_BREADY))
			awready_buf = 1;
	end

	assign	S_WREADY  = axi_wready;
	assign	S_BVALID  = axi_bvalid;
	assign	S_BID     = axi_bid;
	//
	// This core does not produce any bus errors, nor does it support
	// exclusive access, so 2'b00 will always be the correct response.
	assign	S_BRESP = 2'b00;
	// }}}

	////////////////////////////////////////////////////////////////////////
	// Read 
	////////////////////////////////////////////////////////////////////////

	// axi_arready
	// {{{
	always_ff @(posedge ACLK)
	if (!ARESETn)
			axi_arready <= 1;
		else if (S_ARVALID && S_ARREADY)
			axi_arready <= (S_ARLEN==0)&&(o_rd);
		else if (o_rd)
			axi_arready <= (axi_rlen <= 1);

	// axi_rlen
	always_ff @(posedge ACLK) begin
	if (!ARESETn)
		axi_rlen <= 0;
	else if (S_ARVALID && S_ARREADY)
		axi_rlen <= S_ARLEN + (o_rd ? 0 : 1);
	else if (o_rd)
		axi_rlen <= axi_rlen - 1;
	end

	// Next read address calculation
	always_ff @(posedge ACLK)
	if (!ARESETn)
	raddr <= 0;
	else if (o_rd)
		raddr <= next_rd_addr;
	else if (S_ARREADY && S_ARVALID) begin
		raddr <= S_ARADDR;
	end
	// r*
	always_ff @(posedge ACLK)
	if (~ARESETn) begin
		rburst   <= 0;
		rsize    <= 0;
		rlen     <= 0;
		rid      <= 0;
	end else if (S_ARREADY && S_ARVALID) begin
		rburst   <= S_ARBURST;
		rsize    <= S_ARSIZE;
		rlen     <= S_ARLEN;
		rid      <= S_ARID;
	end

	axi_addr #(
		// {{{
		.AW(ADDR_WIDTH), .DW(DATA_WIDTH)
		// }}}
	) get_next_rd_addr(
		// {{{
		(S_ARREADY ? S_ARADDR : raddr),
		(S_ARREADY  ? S_ARSIZE : rsize),
		(S_ARREADY  ? S_ARBURST: rburst),
		(S_ARREADY  ? S_ARLEN  : rlen),
		next_rd_addr
		// }}}
	);


	// o_rd
	always_comb begin
		o_rd = (S_ARVALID || !S_ARREADY);
		if (S_RVALID && !S_RREADY)
			o_rd = 0;
		if (rskd_valid && !rskd_ready)
			o_rd = 0;
	  o_raddr = (S_ARREADY ? S_ARADDR[ADDR_WIDTH-1:LSB] : raddr[ADDR_WIDTH-1:LSB]);
    end

	// rskd_valid
	always_ff @(posedge ACLK)
	if (~ARESETn)
		rskd_valid <= 0;
	else if (o_rd)
		rskd_valid <= 1;
	else if (rskd_ready)
		rskd_valid <= 0;

	// rskd_id
	// {{{
	always_ff @(posedge ACLK)
    if (!ARESETn)
		rskd_id <= 0;
	else if (!rskd_valid || rskd_ready)
	begin
		if (S_ARVALID && S_ARREADY)
			rskd_id <= S_ARID;
		else
			rskd_id <= rid;
	end
	// }}}

	// rskd_last

	always_ff @(posedge ACLK)
    if (!ARESETn)
      rskd_last <= 0;
	else if (!rskd_valid || rskd_ready)
	begin
		rskd_last <= 0;
		if (o_rd && axi_rlen == 1)
			rskd_last <= 1;
		if (S_ARVALID && S_ARREADY && S_ARLEN == 0)
			rskd_last <= 1;
	end

	//read skidbuffer
	skid_buffer #(
	.DWIDTH(32+4+1)  // RDATA + RID + RLAST
	) r_skid_buf (
	.clk    (ACLK),
	.rstn   (ARESETn),

	// Upstream (from AXI slave core)
	.i_data ({rskd_id, rskd_last, i_rdata}),
	.i_valid(rskd_valid),
	.o_ready(rskd_ready),   

	// Downstream (to AXI master)
	.o_data ({S_RID, S_RLAST, S_RDATA}),
	.o_valid(S_RVALID),
	.i_ready(S_RREADY)
	);

	assign	S_RRESP = 2'b00; 
	assign	S_ARREADY = axi_arready;



endmodule