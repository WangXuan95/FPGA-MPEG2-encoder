
//--------------------------------------------------------------------------------------------------------
// Module  : tb_mpeg2encoder
// Type    : simulation, top
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: this testbench is a testbench for mpeg2encoder.v
//           It can read the original video pixels from a file, send them to mpeg2encoder, and write the MPEG2 stream output by the mpeg2encoder to a .m2v file.
//           Note: The. m2v file has good compatibility and can be opened by the video viewers (e.g. Windows media player).
//           To conduct a more comprehensive test, this testbench will execute the above process 3 times (i.e. encode 3 different videos successively)
//--------------------------------------------------------------------------------------------------------

`timescale 1ps/1ps

module tb_mpeg2encoder ();




//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// simulation parameters
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

localparam XL = 7;         // max horizontal pixel count.  4->256 pixels  5->512 pixels  6->1024 pixels  7->2048 pixels .
localparam YL = 6;         // max vertical   pixel count.  4->256 pixels  5->512 pixels  6->1024 pixels  7->2048 pixels .

// video 1 --------------------------------------------------------------------------------------------
`define VIDEO1_IN_YUV_RAW_FILE  "./data/288x208.yuv"
`define VIDEO1_OUT_MPEG2_FILE   "./data/288x208.m2v"
`define VIDEO1_XSIZE  288
`define VIDEO1_YSIZE  208

// video 2 --------------------------------------------------------------------------------------------
`define VIDEO2_IN_YUV_RAW_FILE  "./data/640x320.yuv"
`define VIDEO2_OUT_MPEG2_FILE   "./data/640x320.m2v"
`define VIDEO2_XSIZE  640
`define VIDEO2_YSIZE  320

// video 3 --------------------------------------------------------------------------------------------
`define VIDEO3_IN_YUV_RAW_FILE  "./data/1440x704.yuv"
`define VIDEO3_OUT_MPEG2_FILE   "./data/1440x704.m2v"
`define VIDEO3_XSIZE  1440
`define VIDEO3_YSIZE  704




//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// these arrays save a frame to be encoded, which contains Y U V pixels
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg [7:0] frameY [0:2047] [0:2047];
reg [7:0] frameU [0:2047] [0:2047];
reg [7:0] frameV [0:2047] [0:2047];




//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// clock
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg rstn = 1'b1;
reg clk = 1'b0;
always #10000 clk = ~clk;           // 50 MHz.




//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// signals of the MPEG2 encoder
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg          i_sequence_stop = 0;
wire         o_sequence_busy;

reg  [ XL:0] i_xsize16;
reg  [ YL:0] i_ysize16;

reg          i_en = 0;
reg  [  7:0] i_Y0, i_Y1, i_Y2, i_Y3;
reg  [  7:0] i_U0, i_U1, i_U2, i_U3;
reg  [  7:0] i_V0, i_V1, i_V2, i_V3;

wire         o_en;
wire         o_last;
wire [255:0] o_data;




//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// MPEG2 encoder instance
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

mpeg2encoder #(
    .XL                 ( XL                  ),
    .YL                 ( YL                  ),
    .VECTOR_LEVEL       ( 3                   ),
    .Q_LEVEL            ( 2                   )
) mpeg2encoder_i (
    .rstn               ( rstn                ),
    .clk                ( clk                 ),
    // Video sequence configuration interface.
    .i_xsize16          ( i_xsize16           ),
    .i_ysize16          ( i_ysize16           ),
    .i_pframes_count    ( 8'd23               ),
    // Video sequence input pixel stream interface. In each clock cycle, this interface can input 4 adjacent pixels in a row. Pixel format is YUV 4:4:4, the module will convert it to YUV 4:2:0, then compress it to MPEG2 stream.
    .i_en               ( i_en                ),
    .i_Y0               ( i_Y0                ),
    .i_Y1               ( i_Y1                ),
    .i_Y2               ( i_Y2                ),
    .i_Y3               ( i_Y3                ),
    .i_U0               ( i_U0                ),
    .i_U1               ( i_U1                ),
    .i_U2               ( i_U2                ),
    .i_U3               ( i_U3                ),
    .i_V0               ( i_V0                ),
    .i_V1               ( i_V1                ),
    .i_V2               ( i_V2                ),
    .i_V3               ( i_V3                ),
    // Video sequence control interface.
    .i_sequence_stop    ( i_sequence_stop     ),
    .o_sequence_busy    ( o_sequence_busy     ),
    // Video sequence output MPEG2 stream interface.
    .o_en               ( o_en                ),
    .o_last             ( o_last              ),
    .o_data             ( o_data              )
);




//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// main test program
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

integer fp_in, fp_out;
integer xsize, ysize;
integer num_video;
integer f, y, x, i;

initial begin
    
    repeat(4) @(posedge clk);
    rstn <= 1'b0;                        // reset
    repeat(4) @(posedge clk);
    rstn <= 1'b1;                        // release reset
    @(posedge clk);
    
    for(num_video=1; num_video<=3; num_video=num_video+1) begin
        
        case (num_video)
            1 : begin
                fp_in  = $fopen(`VIDEO1_IN_YUV_RAW_FILE, "rb");
                fp_out = $fopen(`VIDEO1_OUT_MPEG2_FILE , "wb");
                xsize  = `VIDEO1_XSIZE;
                ysize  = `VIDEO1_YSIZE;
            end
            2 : begin
                fp_in  = $fopen(`VIDEO2_IN_YUV_RAW_FILE, "rb");
                fp_out = $fopen(`VIDEO2_OUT_MPEG2_FILE , "wb");
                xsize  = `VIDEO2_XSIZE;
                ysize  = `VIDEO2_YSIZE;
            end
            3 : begin
                fp_in  = $fopen(`VIDEO3_IN_YUV_RAW_FILE, "rb");
                fp_out = $fopen(`VIDEO3_OUT_MPEG2_FILE , "wb");
                xsize  = `VIDEO3_XSIZE;
                ysize  = `VIDEO3_YSIZE;
            end
        endcase
        
        $display("start to encode video %1d (%4dx%4d)", num_video, xsize, ysize);
        
        if (fp_in == 0) begin
            $display("*** couldn't open input file");
            $fclose(fp_in);
            $fclose(fp_out);
            $finish;
        end
        
        if (fp_out == 0) begin
            $display("*** couldn't open output file");
            $fclose(fp_in);
            $fclose(fp_out);
            $finish;
        end
        
        if ( xsize < 64 || xsize > (16<<XL) || (xsize%16) != 0 ) begin
            $display("*** xsize=%4d is invalid, which must in range [64,%4d], and must be a multiple of 16", xsize, (16<<XL) );
            $fclose(fp_in);
            $fclose(fp_out);
            $finish;
        end
        
        if ( ysize < 64 || ysize > (16<<YL) || (ysize%16) != 0 ) begin
            $display("*** ysize=%4d is invalid, which must in range [64,%4d], and must be a multiple of 16", ysize, (16<<YL) );
            $fclose(fp_in);
            $fclose(fp_out);
            $finish;
        end
        
        i_xsize16 <= xsize / 16;
        i_ysize16 <= ysize / 16;
        
        fork
            // thread : push raw pixels to mpeg2encoder -----------------------------------------------------------------
            begin
                // load a frame ----------------------------
                for (y=0; y<ysize; y=y+1)
                    for (x=0; x<xsize; x=x+1)
                        frameY[y][x] = $fgetc(fp_in);
                for (y=0; y<ysize; y=y+1)
                    for (x=0; x<xsize; x=x+1)
                        frameU[y][x] = $fgetc(fp_in);
                for (y=0; y<ysize; y=y+1)
                    for (x=0; x<xsize; x=x+1)
                        frameV[y][x] = $fgetc(fp_in);
                
                for (f=0; !$feof(fp_in); f=f+1) begin
                    $display("  start to encode video %1d frame %3d", num_video, f);
                    
                    // push the pixels of the frame to mpeg2encoder ----------------------------
                    for (y=0; y<ysize; y=y+1) begin
                        for (x=0; x<xsize; x=x+4) begin
                            i_en <= 1'b1;
                            {i_Y0, i_Y1, i_Y2, i_Y3} <= {frameY[y][x], frameY[y][x+1], frameY[y][x+2], frameY[y][x+3]};
                            {i_U0, i_U1, i_U2, i_U3} <= {frameU[y][x], frameU[y][x+1], frameU[y][x+2], frameU[y][x+3]};
                            {i_V0, i_V1, i_V2, i_V3} <= {frameV[y][x], frameV[y][x+1], frameV[y][x+2], frameV[y][x+3]};
                            @(posedge clk);
                            i_en <= 1'b0;
                            
                            //while( $random % 3 == 0 ) @(posedge clk);           // add random bubbles
                        end
                    end
                    
                    // load a frame ----------------------------
                    for (y=0; y<ysize; y=y+1)
                        for (x=0; x<xsize; x=x+1)
                            frameY[y][x] = $fgetc(fp_in);
                    for (y=0; y<ysize; y=y+1)
                        for (x=0; x<xsize; x=x+1)
                            frameU[y][x] = $fgetc(fp_in);
                    for (y=0; y<ysize; y=y+1)
                        for (x=0; x<xsize; x=x+1)
                            frameV[y][x] = $fgetc(fp_in);
                end
                
                i_sequence_stop <= 1'b1;
                @(posedge clk);
                i_sequence_stop <= 1'b0;
                @(posedge clk);
            end
            
            // thread : get mpeg2 stream from mpeg2encoder, and write it to file -----------------------------------------------------------------
            begin
                while (~o_sequence_busy)              // wait until o_sequence_busy = 1 (sequence start)
                    @(posedge clk);
                while (o_sequence_busy) begin         // wait until o_sequence_busy = 0 (sequence end)
                    if (o_en)
                        for(i=0; i<32; i=i+1)
                            $fwrite(fp_out, "%c", o_data[i*8 +: 8] );
                    @(posedge clk);
                end
            end
        join
        
        $fclose(fp_in);
        $fclose(fp_out);
        $display("end of video %1d", num_video);
    end
    
    $finish;
end




// initial $dumpvars(1, mpeg2encoder_i);


endmodule
