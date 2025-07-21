module mem_simple #(
  parameter ADDR_WIDTH = 10,
  parameter DATA_WIDTH = 32
)(
  input  logic                     clk,
  input  logic                     we,
  input  logic [ADDR_WIDTH-1:0]    waddr,
  input  logic [DATA_WIDTH-1:0]    wdata,
  input  logic [DATA_WIDTH/8-1:0]  wstrb,

  input  logic                     rd,
  input  logic [ADDR_WIDTH-1:0]    raddr,
  output logic [DATA_WIDTH-1:0]    rdata
);

  logic [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

  // write
  always_ff @(posedge clk) begin
    if (we) begin
      for (int i = 0; i < DATA_WIDTH/8; i++) begin
        if (wstrb[i])
          mem[waddr][8*i +: 8] <= wdata[8*i +: 8];
      end
    end
  end

  // read
  always_ff @(posedge clk) begin
    if (rd)
      rdata <= mem[raddr];
  end

endmodule
