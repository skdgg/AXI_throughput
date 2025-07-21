`include "./src/sfifo.v"
module axi_master #(
  parameter ID_WIDTH    = 1,
  parameter ADDR_WIDTH  = 10,
  parameter DATA_WIDTH  = 32,
  parameter	LGMAXBURST= 8,	// 256 beats
  parameter	LGFIFO = LGMAXBURST + 1,	// 512 element FIFO
  parameter	LGLEN = ADDR_WIDTH,
  localparam	ADDRLSB= $clog2(DATA_WIDTH)-3,
  localparam	LGLENW= LGLEN-ADDRLSB
)(
  input  logic                     ACLK,
  input  logic                     ARESETn,
  //control
  input  logic                     w_start, //dma like master
  input  logic [ADDR_WIDTH-1:0]    r_src_addr,
  input  logic [ADDR_WIDTH-1:0]    r_dst_addr,
  input  logic [LGLEN-1:0]         r_len,	// Length of transfer read (byte)
  // AXI Write Address Channel
  output logic                     M_AXI_AWVALID,
  input  logic                     M_AXI_AWREADY,
  output logic [ID_WIDTH-1:0]      M_AXI_AWID,  //not used yet
  output logic [ADDR_WIDTH-1:0]    M_AXI_AWADDR,
  output logic [7:0]               M_AXI_AWLEN, //burst length - 1
  output logic [2:0]               M_AXI_AWSIZE, //beat size
  output logic [1:0]               M_AXI_AWBURST,  //INCR

  // AXI Write Data Channel
  output logic                     M_AXI_WVALID,
  input  logic                     M_AXI_WREADY,
  output logic [DATA_WIDTH-1:0]    M_AXI_WDATA,
  output logic [DATA_WIDTH/8-1:0]  M_AXI_WSTRB, //1111
  output logic                     M_AXI_WLAST,

  // AXI Write Response Channel
  input  logic                     M_AXI_BVALID,
  output logic                     M_AXI_BREADY,
  input  logic [ID_WIDTH-1:0]      M_AXI_BID,
  input  logic [1:0]               M_AXI_BRESP, //OKAY

  // AXI Read Address Channel
  output logic                     M_AXI_ARVALID,
  input  logic                     M_AXI_ARREADY,
  output logic [ID_WIDTH-1:0]      M_AXI_ARID,
  output logic [ADDR_WIDTH-1:0]    M_AXI_ARADDR,
  output logic [7:0]               M_AXI_ARLEN, //burst length - 1
  output logic [2:0]               M_AXI_ARSIZE,
  output logic [1:0]               M_AXI_ARBURST,

  // AXI Read Data Channel
  input  logic                     M_AXI_RVALID,
  output logic                     M_AXI_RREADY,
  input  logic [ID_WIDTH-1:0]      M_AXI_RID,
  input  logic [DATA_WIDTH-1:0]    M_AXI_RDATA,
  input  logic                     M_AXI_RLAST,
  input  logic [1:0]               M_AXI_RRESP
);
	// ========================
	// AXI Protocol Constants
	// ========================
	localparam [1:0] AXI_INCR = 2'b01,   // AXI INCR burst type
					AXI_OKAY = 2'b00;   // AXI OKAY response

	localparam MAXBURST = (1 << LGMAXBURST); // max burst 

	// ========================
	// control Flag
	// ========================
	logic r_busy;             // master read or write
	logic last_write_ack;     // last write response（BVALID）
	logic r_done;             // all operations done flag 

	// ========================
	// AXI Read 
	// ========================
	logic                         reads_remaining_nonzero;      
	logic [ADDR_WIDTH-1:0]        read_address;                 // next read AXI address
	logic [LGLEN:0]               readlen_b;                    // total read length in bytes

	logic [LGLENW:0]              readlen_w;                    // total read length in words
	logic [LGLENW:0]              initial_readlen_w;            // initial value 

	logic [LGLENW:0]              reads_remaining_w;            // remain read word 
	logic [LGLENW:0]              read_beats_remaining_w;       // remain beats in a burst
	logic [LGLENW:0]              read_bursts_outstanding;      // outstanding read bursts

	logic                         phantom_read;                 // read init
	logic                         w_start_read;                 // read burst trigger signal
	logic                         no_read_bursts_outstanding;   // all read bursts completed 

	// ========================
	// FIFO 
	// ========================
	logic        [LGFIFO:0]       fifo_space_available;         // FIFO remaining space (writable)
	logic        [LGFIFO:0]       fifo_data_available;         // FIFO available data count
	logic        [LGFIFO:0]       next_fifo_data_available;    // predicted FIFO next cycle data count

	logic                         fifo_reset;                   // reset FIFO flag
	logic                         fifo_full;                    // FIFO full
	logic                         fifo_empty;                   // FIFO empty
	logic                         fifo_fill;                    // FIFO current fill level
	logic                         r_write_fifo;                 // FIFO write enable
	logic                         r_read_fifo;                  // FIFO read enable

	// ========================
	// AXI Write 
	// ========================
	logic                         phantom_write;                // write address fire
	logic                         w_write_start;                // write burst trigger signal
	logic                         AWVALID_start;                // for high throughput, AWVALID start signal

	logic [ADDR_WIDTH-1:0]        write_address;                // next write AXI addr
	logic [LGLEN:0]               writelen_b;                   // total write length in bytes

	logic [LGLENW:0]              w_writes_remaining_w;         // current write remaining word count
	logic [LGLENW:0]              writes_remaining_w;           

	logic [LGLENW:0]              write_bursts_outstanding;     // outstanding write bursts
	logic                         write_requests_remaining;     

	logic [LGLENW:0]              write_burst_length;           
	logic [8:0]                   write_count;                  

	////////////////////////////////////////////////////////////////////////
	// control master
	////////////////////////////////////////////////////////////////////////
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn) begin
		r_busy <= 1'b0;
	end else if (!r_busy && w_start) begin
		r_busy <= 1'b1;
	end else if (r_busy) begin
		if (M_AXI_BVALID && M_AXI_BREADY && last_write_ack)
		r_busy <= 1'b0;
		else if (r_done)
		r_busy <= 1'b0;
	end
	end

	////////////////////////////////////////////////////////////////////////
	// AXI read processing
	////////////////////////////////////////////////////////////////////////

	//
	// Read data into our FIFO
	//

	// read_address
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn) begin
		read_address <= '0;
	end else if (!r_busy) begin
		read_address <= r_src_addr;
	end else if (phantom_read) begin
		read_address[ADDR_WIDTH-1:ADDRLSB] <= read_address[ADDR_WIDTH-1:ADDRLSB] + (M_AXI_ARLEN + 1);
		read_address[ADDRLSB-1:0]        <= '0;
	end
	end

	// Track how many beats are still remaining to be issued as bursts
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn) begin
		reads_remaining_w       <= '0;
		reads_remaining_nonzero <= 1'b0;
	end else if (!r_busy) begin
		reads_remaining_w       <= readlen_b[LGLEN:ADDRLSB];
		reads_remaining_nonzero <= 1'b1;
	end else if (phantom_read) begin
		reads_remaining_w       <= reads_remaining_w - (M_AXI_ARLEN + 1);
		reads_remaining_nonzero <= (reads_remaining_w != (M_AXI_ARLEN + 1));
	end
	end

	// read_bursts_outstanding, no_read_bursts_outstanding
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn) begin
		read_bursts_outstanding <= '0;
	end else if (!r_busy) begin
		read_bursts_outstanding <= '0;
	end else begin
		case ({phantom_read, M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST})
		2'b10: read_bursts_outstanding <= read_bursts_outstanding + 1;
		2'b01: read_bursts_outstanding <= read_bursts_outstanding - 1;
		default: ; 
		endcase
	end
	end

	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || !r_busy) begin
		no_read_bursts_outstanding <= 1'b1;
	end else begin
		case ({phantom_read, M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST})
		2'b01: no_read_bursts_outstanding <= (read_bursts_outstanding == 1);
		2'b10: no_read_bursts_outstanding <= 1'b0;
		default: ; 
		endcase
	end
	end

	// M_AXI_ARADDR
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn) begin
		M_AXI_ARADDR <= '0;
	end else if (!r_busy) begin
		M_AXI_ARADDR <= w_start ? r_src_addr : '0;
	end else if (!M_AXI_ARVALID || M_AXI_ARREADY) begin
		M_AXI_ARADDR <= read_address[ADDR_WIDTH-1:0];
	end
	end

	// readlen_b
	always_comb begin
		readlen_b = {1'b0, r_len};              //init length
		readlen_b[ADDRLSB-1:0] = '0;            // to word-align
	end

	// initial_readlen_w
	always_comb begin
	logic [LGLEN-ADDRLSB:0] total_beats;
	total_beats = readlen_b[LGLEN:ADDRLSB];

	if (total_beats > (1 << LGMAXBURST)) begin
		initial_readlen_w = (1 << LGMAXBURST);
	end else begin
		initial_readlen_w = total_beats;
	end
	end

	// readlen_w
	always_ff @(posedge ACLK) begin
	if (!r_busy) begin
		readlen_w <= initial_readlen_w;
	end else if (phantom_read) begin
		if (reads_remaining_w - (M_AXI_ARLEN+1) > MAXBURST)
		readlen_w <= MAXBURST;
		else
		readlen_w <= reads_remaining_w - (M_AXI_ARLEN+1);
	end
	end


	// w_start_read
	always_comb begin
	w_start_read = r_busy && reads_remaining_nonzero;

	if (phantom_read)
		w_start_read = 1'b0;

	if (fifo_space_available < MAXBURST)
		w_start_read = 1'b0;

	if (M_AXI_ARVALID && !M_AXI_ARREADY)
		w_start_read = 1'b0;
	end


	// M_AXI_ARVALID stay high to allow continuous read bursts!!
	// Read Address Channel Valid and Phantom Flag
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || !r_busy) begin
		M_AXI_ARVALID <= 1'b0;
		phantom_read  <= 1'b0;
	end else if (!M_AXI_ARVALID || M_AXI_ARREADY) begin
		M_AXI_ARVALID <= w_start_read;
		phantom_read  <= w_start_read;
	end else begin
		phantom_read <= 1'b0;
	end
	end

	// Read Address Length
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || !r_busy) begin
		M_AXI_ARLEN <= 8'd0;
	end else if (!M_AXI_ARVALID || M_AXI_ARREADY) begin
		// AXI4: ARLEN = burst length - 1
		M_AXI_ARLEN <= readlen_w[7:0] - 8'd1;
	end
	end


	assign	M_AXI_ARID    = 0;
	assign	M_AXI_ARBURST = AXI_INCR;
	assign	M_AXI_ARSIZE  = ADDRLSB[2:0];
	//assign	M_AXI_ARLOCK  = 1'b0;
	//assign	M_AXI_ARCACHE = 4'b0011;
	//assign	M_AXI_ARPROT  = r_prot;
	//assign	M_AXI_ARQOS   = r_qos;
		//
	assign	M_AXI_RREADY = !no_read_bursts_outstanding;
	// }}}

	////////////////////////////////////////////////////////////////////////
	// FIFO
	////////////////////////////////////////////////////////////////////////

	always_comb begin
	fifo_reset = (!ARESETn || !r_busy || r_done);
	end

	//ALIGNED_FIFO
	always_comb begin
		r_write_fifo         = M_AXI_RVALID;          // AXI read data ready
		r_read_fifo          = M_AXI_WVALID && M_AXI_WREADY;  // ready to write
	end


	sfifo #(
		.BW(DATA_WIDTH),
		.LGFLEN(LGFIFO)
	) middata(
		ACLK, fifo_reset,
			r_write_fifo, M_AXI_RDATA, fifo_full, fifo_fill,
			r_read_fifo,  M_AXI_WDATA, fifo_empty
	);

	// Write strobe control (aligned mode, always full write)
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || !r_busy) begin
		M_AXI_WSTRB <= '1;  // All bytes enabled (full write)
	end else if (!M_AXI_WVALID || M_AXI_WREADY) begin
		M_AXI_WSTRB <= '1;  // Always full strobe, no error condition
	end
	end

	// next_fifo_data_available
	always_comb begin
	next_fifo_data_available = fifo_data_available;

	if (phantom_write) begin
		next_fifo_data_available = next_fifo_data_available - (M_AXI_AWLEN + 1);

		if (r_write_fifo && !fifo_full)
		next_fifo_data_available = next_fifo_data_available + 1;
	end
	else if (r_write_fifo && !fifo_full) begin
		next_fifo_data_available = next_fifo_data_available + 1;
	end
	end

	// fifo_data_available
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || !r_busy || r_done) begin
		fifo_data_available <= '0;
	end else begin
		fifo_data_available <= next_fifo_data_available;
	end
	end


	//  phantom_read：fire AR burst need space in FIFO
	// write W channel（WVALID && WREADY）： FIFO -1

	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || fifo_reset) begin
		fifo_space_available <= (1 << LGFIFO);  
	end else begin
		case ({phantom_read, M_AXI_WVALID && M_AXI_WREADY})
		2'b10: begin
			// read burst
			fifo_space_available <= fifo_space_available - (M_AXI_ARLEN + 1);
		end
		2'b01: begin
			// FIFO fire W channel
			fifo_space_available <= fifo_space_available + 1;
		end
		2'b11: begin
			// phantom_read and W channel fire
			fifo_space_available <= fifo_space_available - M_AXI_ARLEN;
		end
		default: begin
			fifo_space_available <= fifo_space_available;
		end
		endcase
	end
	end
	////////////////////////////////////////////////////////////////////////
	// AXI write processing
	////////////////////////////////////////////////////////////////////////
	//

	// Write data from the FIFO to the AXI bus
	//

	// AXI Write Address 
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn) begin
		write_address <= '0;
	end else if (!r_busy) begin
		write_address <= r_dst_addr; // align input to full address
	end else if (phantom_write) begin
		write_address <= write_address + ((M_AXI_AWLEN + 1) << M_AXI_AWSIZE);
		write_address[ADDRLSB-1:0] <= '0; // clear lower bits to force word-alignment
	end
	end


	// writes_remaining_w
	always_comb begin
		w_writes_remaining_w = writes_remaining_w - (M_AXI_AWLEN + 1);
	end

	
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || !r_busy) begin
		writes_remaining_w <= writelen_b[LGLEN:ADDRLSB];
	end else if (phantom_write) begin
		writes_remaining_w <= w_writes_remaining_w;
	end
	end


	// write_requests_remaining
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn) begin
		write_requests_remaining <= 1'b0;
	end else if (!r_busy) begin
		write_requests_remaining <= w_start;
	end else if (phantom_write) begin
		write_requests_remaining <= (writes_remaining_w != (M_AXI_AWLEN + 1));
	end
	end

	// write_bursts_outstanding
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || !r_busy) begin
		write_bursts_outstanding <= 0;
	end else begin
		case ({phantom_write, M_AXI_BVALID && M_AXI_BREADY})
		2'b01: write_bursts_outstanding <= write_bursts_outstanding - 1;
		2'b10: write_bursts_outstanding <= write_bursts_outstanding + 1;
		default: /* no change */;
		endcase
	end
	end


	// last_write_ack
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || !r_busy) begin
		last_write_ack <= 1'b0;
	end else if (writes_remaining_w > (phantom_write ? (M_AXI_AWLEN + 1) : 0)) begin
		last_write_ack <= 1'b0;
	end else begin
		last_write_ack <= (write_bursts_outstanding ==
						((phantom_write ? 0 : 1) + (M_AXI_BVALID ? 1 : 0)));
	end
	end

	// r_done
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn) begin
		r_done <= 1'b0;
	end else if (!r_busy || M_AXI_ARVALID || M_AXI_AWVALID) begin
		r_done <= 1'b0;
	end else if (read_bursts_outstanding > 0) begin
		r_done <= 1'b0;
	end else if (write_bursts_outstanding > (M_AXI_BVALID ? 1 : 0)) begin
		r_done <= 1'b0;
	end else if (writes_remaining_w > 0) begin
		r_done <= 1'b0;
	end else begin
		r_done <= 1'b1;
	end
	end


	// writelen_b
	always_comb begin
		writelen_b = {1'b0, r_len};
		writelen_b[ADDRLSB-1:0] = '0;  
	end

	always_comb begin
	if (writes_remaining_w >= MAXBURST)
		write_burst_length = MAXBURST;
	else
		write_burst_length = writes_remaining_w;
	end


	// write_count
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || !r_busy) begin
		write_count <= '0;
	end else if (w_write_start) begin
		write_count <= write_burst_length;
	end else if (M_AXI_WVALID && M_AXI_WREADY) begin
		write_count <= write_count - 1;
	end
	end

	// M_AXI_WLAST
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || !r_busy) begin
		M_AXI_WLAST <= 1'b0;
	end else if (!M_AXI_WVALID || M_AXI_WREADY) begin
		//  WLAST
		M_AXI_WLAST <= (write_count == 2);
	end
	end


	// w_write_start
	always_comb begin
	w_write_start = 1'b1;

	// FIFO 
	if (fifo_data_available < write_burst_length)
		w_write_start = 1'b0;

	// 
	if (!write_requests_remaining)
		w_write_start = 1'b0;

	// 
	if (phantom_write)
		w_write_start = 1'b0;

	if (M_AXI_AWVALID && !M_AXI_AWREADY)
		w_write_start = 1'b0;

	if (M_AXI_WVALID && (!M_AXI_WLAST || !M_AXI_WREADY))
		w_write_start = 1'b0;

	if (!ARESETn || !r_busy)
		w_write_start = 1'b0;
	end


	// AWVALID_start for continuous write bursts!!
	always_comb begin
	AWVALID_start = 1'b1;

	// FIFO 
	if (fifo_data_available < write_burst_length)
		AWVALID_start = 1'b0;

	// 
	if (!write_requests_remaining)
		AWVALID_start = 1'b0;

	// 
	if (phantom_write)
		AWVALID_start = 1'b0;

	if (M_AXI_AWVALID && !M_AXI_AWREADY)
		AWVALID_start = 1'b0;

	if (M_AXI_WVALID && (write_count != 2 || !M_AXI_WREADY))
		AWVALID_start = 1'b0;

	if (!ARESETn || !r_busy)
		AWVALID_start = 1'b0;
	end

	// M_AXI_AWVALID, phantom_write
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn) begin
		M_AXI_AWVALID <= 1'b0;
		phantom_write <= 1'b0;
	end else if (!M_AXI_AWVALID || M_AXI_AWREADY) begin
		M_AXI_AWVALID <= AWVALID_start;
		phantom_write <= w_write_start;
	end else begin
		phantom_write <= 1'b0;
	end
	end


	// M_AXI_WVALID
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn) begin
		M_AXI_WVALID <= 1'b0;
	end else if (!M_AXI_WVALID || M_AXI_WREADY) begin
		if (w_write_start) begin
		M_AXI_WVALID <= 1'b1;
		end
		else if (M_AXI_WVALID && !M_AXI_WLAST) begin
		M_AXI_WVALID <= 1'b1;
		end
		else begin
		M_AXI_WVALID <= 1'b0;
		end
	end
	end


	// M_AXI_AWLEN
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || !r_busy)
		M_AXI_AWLEN <= 8'd0;
	else if (!M_AXI_AWVALID || M_AXI_AWREADY) begin
		M_AXI_AWLEN <= write_burst_length[7:0] - 8'd1;
	end
	end

	// M_AXI_AWADDR
	always_ff @(posedge ACLK or negedge ARESETn) begin
	if (!ARESETn || !r_busy)
		M_AXI_AWADDR <= r_dst_addr;
	else if (!M_AXI_AWVALID || M_AXI_AWREADY)
		M_AXI_AWADDR <= write_address;
	end

	// Constant Write Attributes
	always_comb begin
	M_AXI_AWID     = 0;
	M_AXI_AWBURST  = AXI_INCR;
	M_AXI_AWSIZE   = ADDRLSB[2:0];
	//M_AXI_AWLOCK   = 1'b0;
	//M_AXI_AWCACHE  = 4'b0011;
	//M_AXI_AWPROT   = r_prot;
	//M_AXI_AWQOS    = r_qos;
	M_AXI_BREADY   = !r_done;
	end


endmodule
