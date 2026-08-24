`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/10 12:49:40
// Design Name: 
// Module Name: fsm
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module fsm(
    input wire clk, rst, frz,
    output reg [1:0] stage
    );
    
    localparam  
    IDLE = 2'b00, 
    EXE = 2'b01;

    initial stage = 2'b00;

    always @(posedge clk) begin
        if (rst) begin
            stage <= EXE;
        end
        else if (frz) begin
            stage <= IDLE;
        end
    end

endmodule
