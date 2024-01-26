
//--------------------------------------------------------------------------------------------------------
// Module  : mpeg2encoder
// Type    : synthesizable, IP's top
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: MPEG2 video encoder
//           input raw pixels and output MPEG2 stream
//--------------------------------------------------------------------------------------------------------

module mpeg2encoder #(
    parameter  XL           = 6,   // determine the max horizontal pixel count.  4->256 pixels  5->512 pixels  6->1024 pixels  7->2048 pixels .
    parameter  YL           = 6,   // determine the max vertical   pixel count.  4->256 pixels  5->512 pixels  6->1024 pixels  7->2048 pixels .
    parameter  VECTOR_LEVEL = 3,   // motion vector range level, must be 1, 2, or 3. The larger the XL, the higher compression ratio, and the more LUT resource is uses.
    parameter  Q_LEVEL      = 2    // quantize level, must be 1, 2, 3 or 4. The larger the Q_LEVEL, the higher compression ratio and the lower quality.
) (
    input  wire        rstn,                     // =0:async reset, =1:normal operation. It MUST be reset before starting to use.
    input  wire        clk,
    
    // Video sequence configuration interface. --------------------------------------------------------------------------------------------------------------
    input  wire [XL:0] i_xsize16,                // horizontal pixel count = i_xsize16*16 . valid range: 4 ~ 2^XL
    input  wire [YL:0] i_ysize16,                // vertical   pixel count = i_ysize16*16 . valid range: 4 ~ 2^YL
    input  wire [ 7:0] i_pframes_count,          // defines the number of P-frames between two I-frames. valid range: 0 ~ 255
    
    // Video sequence input pixel stream interface. In each clock cycle, this interface can input 4 adjacent pixels in a row. Pixel format is YUV 4:4:4, the module will convert it to YUV 4:2:0, then compress it to MPEG2 stream. 
    input  wire        i_en,                     // when i_en=1, 4 adjacent pixels is being inputted,
    input  wire [ 7:0] i_Y0, i_Y1, i_Y2, i_Y3,   // input Y (luminance)
    input  wire [ 7:0] i_U0, i_U1, i_U2, i_U3,   // input U (Cb, chroma blue)
    input  wire [ 7:0] i_V0, i_V1, i_V2, i_V3,   // input V (Cr, chroma red)
    
    // Video sequence control interface. --------------------------------------------------------------------------------------------------------------------
    input  wire        i_sequence_stop,          // use this signal to stop a inputting video sequence
    output wire        o_sequence_busy,          // =0: the module is idle and ready to encode the next sequence. =1: the module is busy encoding the current sequence
    
    // Video sequence output MPEG2 stream interface. --------------------------------------------------------------------------------------------------------
    output wire        o_en,                     // o_en=1 indicates o_data is valid
    output wire        o_last,                   // o_en=1 & o_last=1 indicates this is the last data of a video sequence
    output wire[255:0] o_data                    // output mpeg2 stream data, 32 bytes in LITTLE ENDIAN, i.e., o_data[7:0] is the 1st byte, o_data[15:8] is the 2nd byte, ... o_data[255:248] is the 32nd byte.
);



//
// Definition of nouns:
//     tile        : 8x8 pixels, the unit of DCT, quantize and zig-zag reorder
//     block (blk) : contains 16x16 U pixels (4 tiles of Y, 1 tile of U, 1 tile of V)
//     slice       : a line of block (16 lines of pixels)
//
// Note : 
//     right shift: for signed number, use ">>>" rather than ">>". for unsigned number, using ">>>" and ">>" are both okay.
//




//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// local parameters : frame size
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
localparam XB16 = XL       ,  YB16 = YL      ;
localparam XB8  = XB16 + 1 ,  YB8  = YB16 + 1;
localparam XB4  = XB8  + 1 ,  YB4  = YB8  + 1;
localparam XB2  = XB4  + 1 ,  YB2  = YB4  + 1;
localparam XB   = XB2  + 1 ,  YB   = YB2  + 1;

localparam XSIZE = (1 << XB);                           // horizontal max pixel count
localparam YSIZE = (1 << YB);                           // vertical   max pixel count


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// local parameters : motion estimation
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
localparam UR =  VECTOR_LEVEL;                          // U/V motion vector range is in -YR~+YR pixels
localparam YR =  UR * 2;                                // Y motion vector range is in -YR~+YR pixels


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// local parameters : DCT
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// localparam DCTP = 2;
// localparam logic signed [9:0] DCTM [8][8] = '{
//     '{ 256,  256,  256,  256,  256,  256,  256,  256 },
//     '{ 355,  301,  201,   71,  -71, -201, -301, -355 },
//     '{ 334,  139, -139, -334, -334, -139,  139,  334 },
//     '{ 301,  -71, -355, -201,  201,  355,   71, -301 },
//     '{ 256, -256, -256,  256,  256, -256, -256,  256 },
//     '{ 201, -355,   71,  301, -301,  -71,  355, -201 },
//     '{ 139, -334,  334, -139, -139,  334, -334,  139 },
//     '{  71, -201,  301, -355,  355, -301,  201,  -71 }
// };

// localparam DCTP = 0;
// localparam signed [7:0] DCTM [8][8] = '{
//     '{ 64,  64,  64,  64,  64,  64,  64,  64 },
//     '{ 89,  75,  50,  18, -18, -50, -75, -89 },
//     '{ 84,  35, -35, -84, -84, -35,  35,  84 },
//     '{ 75, -18, -89, -50,  50,  89,  18, -75 },
//     '{ 64, -64, -64,  64,  64, -64, -64,  64 },
//     '{ 50, -89,  18,  75, -75, -18,  89, -50 },
//     '{ 35, -84,  84, -35, -35,  84, -84,  35 },
//     '{ 18, -50,  75, -89,  89, -75,  50, -18 }
// };

localparam DCTP = 0;

wire signed [7:0] DCTM [0:7] [0:7];
assign DCTM[0][0] = 64;  assign DCTM[0][1] = 64;  assign DCTM[0][2] = 64;  assign DCTM[0][3] = 64;  assign DCTM[0][4] = 64;  assign DCTM[0][5] = 64;  assign DCTM[0][6] = 64;  assign DCTM[0][7] = 64;
assign DCTM[1][0] = 89;  assign DCTM[1][1] = 75;  assign DCTM[1][2] = 50;  assign DCTM[1][3] = 18;  assign DCTM[1][4] =-18;  assign DCTM[1][5] =-50;  assign DCTM[1][6] =-75;  assign DCTM[1][7] =-89;
assign DCTM[2][0] = 84;  assign DCTM[2][1] = 35;  assign DCTM[2][2] =-35;  assign DCTM[2][3] =-84;  assign DCTM[2][4] =-84;  assign DCTM[2][5] =-35;  assign DCTM[2][6] = 35;  assign DCTM[2][7] = 84;
assign DCTM[3][0] = 75;  assign DCTM[3][1] =-18;  assign DCTM[3][2] =-89;  assign DCTM[3][3] =-50;  assign DCTM[3][4] = 50;  assign DCTM[3][5] = 89;  assign DCTM[3][6] = 18;  assign DCTM[3][7] =-75;
assign DCTM[4][0] = 64;  assign DCTM[4][1] =-64;  assign DCTM[4][2] =-64;  assign DCTM[4][3] = 64;  assign DCTM[4][4] = 64;  assign DCTM[4][5] =-64;  assign DCTM[4][6] =-64;  assign DCTM[4][7] = 64;
assign DCTM[5][0] = 50;  assign DCTM[5][1] =-89;  assign DCTM[5][2] = 18;  assign DCTM[5][3] = 75;  assign DCTM[5][4] =-75;  assign DCTM[5][5] =-18;  assign DCTM[5][6] = 89;  assign DCTM[5][7] =-50;
assign DCTM[6][0] = 35;  assign DCTM[6][1] =-84;  assign DCTM[6][2] = 84;  assign DCTM[6][3] =-35;  assign DCTM[6][4] =-35;  assign DCTM[6][5] = 84;  assign DCTM[6][6] =-84;  assign DCTM[6][7] = 35;
assign DCTM[7][0] = 18;  assign DCTM[7][1] =-50;  assign DCTM[7][2] = 75;  assign DCTM[7][3] =-89;  assign DCTM[7][4] = 89;  assign DCTM[7][5] =-75;  assign DCTM[7][6] = 50;  assign DCTM[7][7] =-18;



//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// local parameters : quantize
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// localparam [6:0] INTRA_Q [8][8] = '{
//     '{  8, 16, 19, 22, 26, 27, 29, 34 },
//     '{ 16, 16, 22, 24, 27, 29, 34, 37 },
//     '{ 19, 22, 26, 27, 29, 34, 34, 38 },
//     '{ 22, 22, 26, 27, 29, 34, 37, 40 },
//     '{ 22, 26, 27, 29, 32, 35, 40, 48 },
//     '{ 26, 27, 29, 32, 35, 40, 48, 58 },
//     '{ 26, 27, 29, 34, 38, 46, 56, 69 },
//     '{ 27, 29, 35, 38, 46, 56, 69, 83 }
// };

wire [6:0] INTRA_Q [0:7][0:7];
assign INTRA_Q[0][0] = 8;  assign INTRA_Q[0][1] = 16; assign INTRA_Q[0][2] = 19; assign INTRA_Q[0][3] = 22; assign INTRA_Q[0][4] = 26; assign INTRA_Q[0][5] = 27; assign INTRA_Q[0][6] = 29; assign INTRA_Q[0][7] = 34;
assign INTRA_Q[1][0] = 16; assign INTRA_Q[1][1] = 16; assign INTRA_Q[1][2] = 22; assign INTRA_Q[1][3] = 24; assign INTRA_Q[1][4] = 27; assign INTRA_Q[1][5] = 29; assign INTRA_Q[1][6] = 34; assign INTRA_Q[1][7] = 37;
assign INTRA_Q[2][0] = 19; assign INTRA_Q[2][1] = 22; assign INTRA_Q[2][2] = 26; assign INTRA_Q[2][3] = 27; assign INTRA_Q[2][4] = 29; assign INTRA_Q[2][5] = 34; assign INTRA_Q[2][6] = 34; assign INTRA_Q[2][7] = 38;
assign INTRA_Q[3][0] = 22; assign INTRA_Q[3][1] = 22; assign INTRA_Q[3][2] = 26; assign INTRA_Q[3][3] = 27; assign INTRA_Q[3][4] = 29; assign INTRA_Q[3][5] = 34; assign INTRA_Q[3][6] = 37; assign INTRA_Q[3][7] = 40;
assign INTRA_Q[4][0] = 22; assign INTRA_Q[4][1] = 26; assign INTRA_Q[4][2] = 27; assign INTRA_Q[4][3] = 29; assign INTRA_Q[4][4] = 32; assign INTRA_Q[4][5] = 35; assign INTRA_Q[4][6] = 40; assign INTRA_Q[4][7] = 48;
assign INTRA_Q[5][0] = 26; assign INTRA_Q[5][1] = 27; assign INTRA_Q[5][2] = 29; assign INTRA_Q[5][3] = 32; assign INTRA_Q[5][4] = 35; assign INTRA_Q[5][5] = 40; assign INTRA_Q[5][6] = 48; assign INTRA_Q[5][7] = 58;
assign INTRA_Q[6][0] = 26; assign INTRA_Q[6][1] = 27; assign INTRA_Q[6][2] = 29; assign INTRA_Q[6][3] = 34; assign INTRA_Q[6][4] = 38; assign INTRA_Q[6][5] = 46; assign INTRA_Q[6][6] = 56; assign INTRA_Q[6][7] = 69;
assign INTRA_Q[7][0] = 27; assign INTRA_Q[7][1] = 29; assign INTRA_Q[7][2] = 35; assign INTRA_Q[7][3] = 38; assign INTRA_Q[7][4] = 46; assign INTRA_Q[7][5] = 56; assign INTRA_Q[7][6] = 69; assign INTRA_Q[7][7] = 83;


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// local parameters : zig-zag reorder
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// localparam [5:0] ZIGZAG [8][8] = '{
//     '{  0,  1,  5,  6, 14, 15, 27, 28 },
//     '{  2,  4,  7, 13, 16, 26, 29, 42 },
//     '{  3,  8, 12, 17, 25, 30, 41, 43 },
//     '{  9, 11, 18, 24, 31, 40, 44, 53 },
//     '{ 10, 19, 23, 32, 39, 45, 52, 54 },
//     '{ 20, 22, 33, 38, 46, 51, 55, 60 },
//     '{ 21, 34, 37, 47, 50, 56, 59, 61 },
//     '{ 35, 36, 48, 49, 57, 58, 62, 63 }
// };

wire [6:0] ZIGZAG [0:7][0:7];
assign ZIGZAG[0][0] = 0;  assign ZIGZAG[0][1] = 1;  assign ZIGZAG[0][2] = 5;  assign ZIGZAG[0][3] = 6;  assign ZIGZAG[0][4] = 14; assign ZIGZAG[0][5] = 15; assign ZIGZAG[0][6] = 27; assign ZIGZAG[0][7] = 28;
assign ZIGZAG[1][0] = 2;  assign ZIGZAG[1][1] = 4;  assign ZIGZAG[1][2] = 7;  assign ZIGZAG[1][3] = 13; assign ZIGZAG[1][4] = 16; assign ZIGZAG[1][5] = 26; assign ZIGZAG[1][6] = 29; assign ZIGZAG[1][7] = 42;
assign ZIGZAG[2][0] = 3;  assign ZIGZAG[2][1] = 8;  assign ZIGZAG[2][2] = 12; assign ZIGZAG[2][3] = 17; assign ZIGZAG[2][4] = 25; assign ZIGZAG[2][5] = 30; assign ZIGZAG[2][6] = 41; assign ZIGZAG[2][7] = 43;
assign ZIGZAG[3][0] = 9;  assign ZIGZAG[3][1] = 11; assign ZIGZAG[3][2] = 18; assign ZIGZAG[3][3] = 24; assign ZIGZAG[3][4] = 31; assign ZIGZAG[3][5] = 40; assign ZIGZAG[3][6] = 44; assign ZIGZAG[3][7] = 53;
assign ZIGZAG[4][0] = 10; assign ZIGZAG[4][1] = 19; assign ZIGZAG[4][2] = 23; assign ZIGZAG[4][3] = 32; assign ZIGZAG[4][4] = 39; assign ZIGZAG[4][5] = 45; assign ZIGZAG[4][6] = 52; assign ZIGZAG[4][7] = 54;
assign ZIGZAG[5][0] = 20; assign ZIGZAG[5][1] = 22; assign ZIGZAG[5][2] = 33; assign ZIGZAG[5][3] = 38; assign ZIGZAG[5][4] = 46; assign ZIGZAG[5][5] = 51; assign ZIGZAG[5][6] = 55; assign ZIGZAG[5][7] = 60;
assign ZIGZAG[6][0] = 21; assign ZIGZAG[6][1] = 34; assign ZIGZAG[6][2] = 37; assign ZIGZAG[6][3] = 47; assign ZIGZAG[6][4] = 50; assign ZIGZAG[6][5] = 56; assign ZIGZAG[6][6] = 59; assign ZIGZAG[6][7] = 61;
assign ZIGZAG[7][0] = 35; assign ZIGZAG[7][1] = 36; assign ZIGZAG[7][2] = 48; assign ZIGZAG[7][3] = 49; assign ZIGZAG[7][4] = 57; assign ZIGZAG[7][5] = 58; assign ZIGZAG[7][6] = 62; assign ZIGZAG[7][7] = 63;


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// local parameters : inverse DCT
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
localparam signed [16:0] W1 = 17'sd2841;     // 2048*sqrt(2)*cos(1*pi/16)
localparam signed [16:0] W2 = 17'sd2676;     // 2048*sqrt(2)*cos(2*pi/16)
localparam signed [16:0] W3 = 17'sd2408;     // 2048*sqrt(2)*cos(3*pi/16)
localparam signed [16:0] W5 = 17'sd1609;     // 2048*sqrt(2)*cos(5*pi/16)
localparam signed [16:0] W6 = 17'sd1108;     // 2048*sqrt(2)*cos(6*pi/16)
localparam signed [16:0] W7 = 17'sd565 ;     // 2048*sqrt(2)*cos(7*pi/16)



//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// local parameters : look-up-tables for variable length code (VLC)
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//localparam logic [4:0] BITS_MOTION_VECTOR [17] = '{5'h01, 5'h01, 5'h01, 5'h01, 5'h03, 5'h05, 5'h04, 5'h03, 5'h0b, 5'h0a, 5'h09, 5'h11, 5'h10, 5'h0f, 5'h0e, 5'h0d, 5'h0c};
//localparam logic [3:0] LENS_MOTION_VECTOR [17] = '{4'd01, 4'd02, 4'd03, 4'd04, 4'd06, 4'd07, 4'd07, 4'd07, 4'd09, 4'd09, 4'd09, 4'd10, 4'd10, 4'd10, 4'd10, 4'd10, 4'd10};

wire [4:0] BITS_MOTION_VECTOR [0:16];
assign BITS_MOTION_VECTOR[0] = 5'h01; assign BITS_MOTION_VECTOR[1] = 5'h01; assign BITS_MOTION_VECTOR[2] = 5'h01; assign BITS_MOTION_VECTOR[3] = 5'h01;
assign BITS_MOTION_VECTOR[4] = 5'h03; assign BITS_MOTION_VECTOR[5] = 5'h05; assign BITS_MOTION_VECTOR[6] = 5'h04; assign BITS_MOTION_VECTOR[7] = 5'h03;
assign BITS_MOTION_VECTOR[8] = 5'h0b; assign BITS_MOTION_VECTOR[9] = 5'h0a; assign BITS_MOTION_VECTOR[10]= 5'h09; assign BITS_MOTION_VECTOR[11]= 5'h11;
assign BITS_MOTION_VECTOR[12]= 5'h10; assign BITS_MOTION_VECTOR[13]= 5'h0f; assign BITS_MOTION_VECTOR[14]= 5'h0e; assign BITS_MOTION_VECTOR[15]= 5'h0d;  assign BITS_MOTION_VECTOR[16]= 5'h0c;

wire [3:0] LENS_MOTION_VECTOR [0:16];
assign LENS_MOTION_VECTOR[0] = 4'd01; assign LENS_MOTION_VECTOR[1] = 4'd02; assign LENS_MOTION_VECTOR[2] = 4'd03; assign LENS_MOTION_VECTOR[3] = 4'd04;
assign LENS_MOTION_VECTOR[4] = 4'd06; assign LENS_MOTION_VECTOR[5] = 4'd07; assign LENS_MOTION_VECTOR[6] = 4'd07; assign LENS_MOTION_VECTOR[7] = 4'd07;
assign LENS_MOTION_VECTOR[8] = 4'd09; assign LENS_MOTION_VECTOR[9] = 4'd09; assign LENS_MOTION_VECTOR[10]= 4'd09; assign LENS_MOTION_VECTOR[11]= 4'd10;
assign LENS_MOTION_VECTOR[12]= 4'd10; assign LENS_MOTION_VECTOR[13]= 4'd10; assign LENS_MOTION_VECTOR[14]= 4'd10; assign LENS_MOTION_VECTOR[15]= 4'd10;  assign LENS_MOTION_VECTOR[16]= 4'd10;



//localparam logic [4:0] BITS_NZ_FLAGS [64] = '{5'h00, 5'h0b, 5'h09, 5'h0d, 5'h0d, 5'h17, 5'h13, 5'h1f, 5'h0c, 5'h16, 5'h12, 5'h1e, 5'h13, 5'h1b, 5'h17, 5'h13, 5'h0b, 5'h15, 5'h11, 5'h1d, 5'h11, 5'h19, 5'h15, 5'h11, 5'h0f, 5'h0f, 5'h0d, 5'h03, 5'h0f, 5'h0b, 5'h07, 5'h07, 5'h0a, 5'h14, 5'h10, 5'h1c, 5'h0e, 5'h0e, 5'h0c, 5'h02, 5'h10, 5'h18, 5'h14, 5'h10, 5'h0e, 5'h0a, 5'h06, 5'h06, 5'h12, 5'h1a, 5'h16, 5'h12, 5'h0d, 5'h09, 5'h05, 5'h05, 5'h0c, 5'h08, 5'h04, 5'h04, 5'h07, 5'h0a, 5'h08, 5'h0c};
//localparam logic [3:0] LENS_NZ_FLAGS [64] = '{4'd00, 4'd05, 4'd05, 4'd06, 4'd04, 4'd07, 4'd07, 4'd08, 4'd04, 4'd07, 4'd07, 4'd08, 4'd05, 4'd08, 4'd08, 4'd08, 4'd04, 4'd07, 4'd07, 4'd08, 4'd05, 4'd08, 4'd08, 4'd08, 4'd06, 4'd08, 4'd08, 4'd09, 4'd05, 4'd08, 4'd08, 4'd09, 4'd04, 4'd07, 4'd07, 4'd08, 4'd06, 4'd08, 4'd08, 4'd09, 4'd05, 4'd08, 4'd08, 4'd08, 4'd05, 4'd08, 4'd08, 4'd09, 4'd05, 4'd08, 4'd08, 4'd08, 4'd05, 4'd08, 4'd08, 4'd09, 4'd05, 4'd08, 4'd08, 4'd09, 4'd03, 4'd05, 4'd05, 4'd06};

wire [4:0] BITS_NZ_FLAGS [0:63];
assign BITS_NZ_FLAGS[0] = 5'h00;  assign BITS_NZ_FLAGS[1] = 5'h0b;  assign BITS_NZ_FLAGS[2] = 5'h09;  assign BITS_NZ_FLAGS[3] = 5'h0d;  assign BITS_NZ_FLAGS[4] = 5'h0d;  assign BITS_NZ_FLAGS[5] = 5'h17;  assign BITS_NZ_FLAGS[6] = 5'h13;  assign BITS_NZ_FLAGS[7] = 5'h1f;
assign BITS_NZ_FLAGS[8] = 5'h0c;  assign BITS_NZ_FLAGS[9] = 5'h16;  assign BITS_NZ_FLAGS[10]= 5'h12;  assign BITS_NZ_FLAGS[11]= 5'h1e;  assign BITS_NZ_FLAGS[12]= 5'h13;  assign BITS_NZ_FLAGS[13]= 5'h1b;  assign BITS_NZ_FLAGS[14]= 5'h17;  assign BITS_NZ_FLAGS[15]= 5'h13;
assign BITS_NZ_FLAGS[16]= 5'h0b;  assign BITS_NZ_FLAGS[17]= 5'h15;  assign BITS_NZ_FLAGS[18]= 5'h11;  assign BITS_NZ_FLAGS[19]= 5'h1d;  assign BITS_NZ_FLAGS[20]= 5'h11;  assign BITS_NZ_FLAGS[21]= 5'h19;  assign BITS_NZ_FLAGS[22]= 5'h15;  assign BITS_NZ_FLAGS[23]= 5'h11;
assign BITS_NZ_FLAGS[24]= 5'h0f;  assign BITS_NZ_FLAGS[25]= 5'h0f;  assign BITS_NZ_FLAGS[26]= 5'h0d;  assign BITS_NZ_FLAGS[27]= 5'h03;  assign BITS_NZ_FLAGS[28]= 5'h0f;  assign BITS_NZ_FLAGS[29]= 5'h0b;  assign BITS_NZ_FLAGS[30]= 5'h07;  assign BITS_NZ_FLAGS[31]= 5'h07;
assign BITS_NZ_FLAGS[32]= 5'h0a;  assign BITS_NZ_FLAGS[33]= 5'h14;  assign BITS_NZ_FLAGS[34]= 5'h10;  assign BITS_NZ_FLAGS[35]= 5'h1c;  assign BITS_NZ_FLAGS[36]= 5'h0e;  assign BITS_NZ_FLAGS[37]= 5'h0e;  assign BITS_NZ_FLAGS[38]= 5'h0c;  assign BITS_NZ_FLAGS[39]= 5'h02;
assign BITS_NZ_FLAGS[40]= 5'h10;  assign BITS_NZ_FLAGS[41]= 5'h18;  assign BITS_NZ_FLAGS[42]= 5'h14;  assign BITS_NZ_FLAGS[43]= 5'h10;  assign BITS_NZ_FLAGS[44]= 5'h0e;  assign BITS_NZ_FLAGS[45]= 5'h0a;  assign BITS_NZ_FLAGS[46]= 5'h06;  assign BITS_NZ_FLAGS[47]= 5'h06;
assign BITS_NZ_FLAGS[48]= 5'h12;  assign BITS_NZ_FLAGS[49]= 5'h1a;  assign BITS_NZ_FLAGS[50]= 5'h16;  assign BITS_NZ_FLAGS[51]= 5'h12;  assign BITS_NZ_FLAGS[52]= 5'h0d;  assign BITS_NZ_FLAGS[53]= 5'h09;  assign BITS_NZ_FLAGS[54]= 5'h05;  assign BITS_NZ_FLAGS[55]= 5'h05;
assign BITS_NZ_FLAGS[56]= 5'h0c;  assign BITS_NZ_FLAGS[57]= 5'h08;  assign BITS_NZ_FLAGS[58]= 5'h04;  assign BITS_NZ_FLAGS[59]= 5'h04;  assign BITS_NZ_FLAGS[60]= 5'h07;  assign BITS_NZ_FLAGS[61]= 5'h0a;  assign BITS_NZ_FLAGS[62]= 5'h08;  assign BITS_NZ_FLAGS[63]= 5'h0c;

wire [3:0] LENS_NZ_FLAGS [0:63];
assign LENS_NZ_FLAGS[0] = 4'd00;  assign LENS_NZ_FLAGS[1] = 4'd05;  assign LENS_NZ_FLAGS[2] = 4'd05;  assign LENS_NZ_FLAGS[3] = 4'd06;  assign LENS_NZ_FLAGS[4] = 4'd04;  assign LENS_NZ_FLAGS[5] = 4'd07;  assign LENS_NZ_FLAGS[6] = 4'd07;  assign LENS_NZ_FLAGS[7] = 4'd08;
assign LENS_NZ_FLAGS[8] = 4'd04;  assign LENS_NZ_FLAGS[9] = 4'd07;  assign LENS_NZ_FLAGS[10]= 4'd07;  assign LENS_NZ_FLAGS[11]= 4'd08;  assign LENS_NZ_FLAGS[12]= 4'd05;  assign LENS_NZ_FLAGS[13]= 4'd08;  assign LENS_NZ_FLAGS[14]= 4'd08;  assign LENS_NZ_FLAGS[15]= 4'd08;
assign LENS_NZ_FLAGS[16]= 4'd04;  assign LENS_NZ_FLAGS[17]= 4'd07;  assign LENS_NZ_FLAGS[18]= 4'd07;  assign LENS_NZ_FLAGS[19]= 4'd08;  assign LENS_NZ_FLAGS[20]= 4'd05;  assign LENS_NZ_FLAGS[21]= 4'd08;  assign LENS_NZ_FLAGS[22]= 4'd08;  assign LENS_NZ_FLAGS[23]= 4'd08;
assign LENS_NZ_FLAGS[24]= 4'd06;  assign LENS_NZ_FLAGS[25]= 4'd08;  assign LENS_NZ_FLAGS[26]= 4'd08;  assign LENS_NZ_FLAGS[27]= 4'd09;  assign LENS_NZ_FLAGS[28]= 4'd05;  assign LENS_NZ_FLAGS[29]= 4'd08;  assign LENS_NZ_FLAGS[30]= 4'd08;  assign LENS_NZ_FLAGS[31]= 4'd09;
assign LENS_NZ_FLAGS[32]= 4'd04;  assign LENS_NZ_FLAGS[33]= 4'd07;  assign LENS_NZ_FLAGS[34]= 4'd07;  assign LENS_NZ_FLAGS[35]= 4'd08;  assign LENS_NZ_FLAGS[36]= 4'd06;  assign LENS_NZ_FLAGS[37]= 4'd08;  assign LENS_NZ_FLAGS[38]= 4'd08;  assign LENS_NZ_FLAGS[39]= 4'd09;
assign LENS_NZ_FLAGS[40]= 4'd05;  assign LENS_NZ_FLAGS[41]= 4'd08;  assign LENS_NZ_FLAGS[42]= 4'd08;  assign LENS_NZ_FLAGS[43]= 4'd08;  assign LENS_NZ_FLAGS[44]= 4'd05;  assign LENS_NZ_FLAGS[45]= 4'd08;  assign LENS_NZ_FLAGS[46]= 4'd08;  assign LENS_NZ_FLAGS[47]= 4'd09;
assign LENS_NZ_FLAGS[48]= 4'd05;  assign LENS_NZ_FLAGS[49]= 4'd08;  assign LENS_NZ_FLAGS[50]= 4'd08;  assign LENS_NZ_FLAGS[51]= 4'd08;  assign LENS_NZ_FLAGS[52]= 4'd05;  assign LENS_NZ_FLAGS[53]= 4'd08;  assign LENS_NZ_FLAGS[54]= 4'd08;  assign LENS_NZ_FLAGS[55]= 4'd09;
assign LENS_NZ_FLAGS[56]= 4'd05;  assign LENS_NZ_FLAGS[57]= 4'd08;  assign LENS_NZ_FLAGS[58]= 4'd08;  assign LENS_NZ_FLAGS[59]= 4'd09;  assign LENS_NZ_FLAGS[60]= 4'd03;  assign LENS_NZ_FLAGS[61]= 4'd05;  assign LENS_NZ_FLAGS[62]= 4'd05;  assign LENS_NZ_FLAGS[63]= 4'd06;



//localparam logic [8:0] BITS_DC_Y  [12] = '{ 9'h004,  9'h000,  9'h001,  9'h005,  9'h006,  9'h00e,  9'h01e,  9'h03e,  9'h07e,  9'h0fe,  9'h1fe,  9'h1ff};
//localparam logic [3:0] LENS_DC_Y  [12] = '{ 4'd003,  4'd002,  4'd002,  4'd003,  4'd003,  4'd004,  4'd005,  4'd006,  4'd007,  4'd008,  4'd009,  4'd009};

//localparam logic [9:0] BITS_DC_UV [12] = '{10'h000, 10'h001, 10'h002, 10'h006, 10'h00e, 10'h01e, 10'h03e, 10'h07e, 10'h0fe, 10'h1fe, 10'h3fe, 10'h3ff};
//localparam logic [3:0] LENS_DC_UV [12] = '{ 4'd002,  4'd002,  4'd002,  4'd003,  4'd004,  4'd005,  4'd006,  4'd007,  4'd008,  4'd009,  4'd010,  4'd010};

wire [8:0] BITS_DC_Y [0:11];
assign BITS_DC_Y[0] = 9'h004;  assign BITS_DC_Y[1] = 9'h000;  assign BITS_DC_Y[2] = 9'h001;  assign BITS_DC_Y[3] = 9'h005;
assign BITS_DC_Y[4] = 9'h006;  assign BITS_DC_Y[5] = 9'h00e;  assign BITS_DC_Y[6] = 9'h01e;  assign BITS_DC_Y[7] = 9'h03e;
assign BITS_DC_Y[8] = 9'h07e;  assign BITS_DC_Y[9] = 9'h0fe;  assign BITS_DC_Y[10]= 9'h1fe;  assign BITS_DC_Y[11]= 9'h1ff;
wire [3:0] LENS_DC_Y [0:11];
assign LENS_DC_Y[0] = 4'd003;  assign LENS_DC_Y[1] = 4'd002;  assign LENS_DC_Y[2] = 4'd002;  assign LENS_DC_Y[3] = 4'd003;
assign LENS_DC_Y[4] = 4'd003;  assign LENS_DC_Y[5] = 4'd004;  assign LENS_DC_Y[6] = 4'd005;  assign LENS_DC_Y[7] = 4'd006;
assign LENS_DC_Y[8] = 4'd007;  assign LENS_DC_Y[9] = 4'd008;  assign LENS_DC_Y[10]= 4'd009;  assign LENS_DC_Y[11]= 4'd009;

wire [9:0] BITS_DC_UV [0:11];
assign BITS_DC_UV[0] = 10'h000;  assign BITS_DC_UV[1] = 10'h001;  assign BITS_DC_UV[2] = 10'h002;  assign BITS_DC_UV[3] = 10'h006;
assign BITS_DC_UV[4] = 10'h00e;  assign BITS_DC_UV[5] = 10'h01e;  assign BITS_DC_UV[6] = 10'h03e;  assign BITS_DC_UV[7] = 10'h07e;
assign BITS_DC_UV[8] = 10'h0fe;  assign BITS_DC_UV[9] = 10'h1fe;  assign BITS_DC_UV[10]= 10'h3fe;  assign BITS_DC_UV[11]= 10'h3ff;
wire [3:0] LENS_DC_UV [0:11];
assign LENS_DC_UV[0] = 4'd002;  assign LENS_DC_UV[1] = 4'd002;  assign LENS_DC_UV[2] = 4'd002;  assign LENS_DC_UV[3] = 4'd003;
assign LENS_DC_UV[4] = 4'd004;  assign LENS_DC_UV[5] = 4'd005;  assign LENS_DC_UV[6] = 4'd006;  assign LENS_DC_UV[7] = 4'd007;
assign LENS_DC_UV[8] = 4'd008;  assign LENS_DC_UV[9] = 4'd009;  assign LENS_DC_UV[10]= 4'd010;  assign LENS_DC_UV[11]= 4'd010;



//localparam logic [5:0] BITS_AC_0_3 [4][40] = '{
//  '{6'h03, 6'h04, 6'h05, 6'h06, 6'h26, 6'h21, 6'h0a, 6'h1d, 6'h18, 6'h13, 6'h10, 6'h1a, 6'h19, 6'h18, 6'h17, 6'h1f, 6'h1e, 6'h1d, 6'h1c, 6'h1b, 6'h1a, 6'h19, 6'h18, 6'h17, 6'h16, 6'h15, 6'h14, 6'h13, 6'h12, 6'h11, 6'h10, 6'h18, 6'h17, 6'h16, 6'h15, 6'h14, 6'h13, 6'h12, 6'h11, 6'h10},    // runlen=0 , absvm1<40
//  '{6'h03, 6'h06, 6'h25, 6'h0c, 6'h1b, 6'h16, 6'h15, 6'h1f, 6'h1e, 6'h1d, 6'h1c, 6'h1b, 6'h1a, 6'h19, 6'h13, 6'h12, 6'h11, 6'h10, 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 },    // runlen=1 , absvm1<18
//  '{6'h05, 6'h04, 6'h0b, 6'h14, 6'h14, 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 },    // runlen=2 , absvm1<5
//  '{6'h07, 6'h24, 6'h1c, 6'h13, 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 }     // runlen=3 , absvm1<4
//};

wire [5:0] BITS_AC_0_3 [0:3][0:39];

assign BITS_AC_0_3[0][0] = 6'h03;
assign BITS_AC_0_3[0][1] = 6'h04;
assign BITS_AC_0_3[0][2] = 6'h05;
assign BITS_AC_0_3[0][3] = 6'h06;
assign BITS_AC_0_3[0][4] = 6'h26;
assign BITS_AC_0_3[0][5] = 6'h21;
assign BITS_AC_0_3[0][6] = 6'h0a;
assign BITS_AC_0_3[0][7] = 6'h1d;
assign BITS_AC_0_3[0][8] = 6'h18;
assign BITS_AC_0_3[0][9] = 6'h13;
assign BITS_AC_0_3[0][10]= 6'h10;
assign BITS_AC_0_3[0][11]= 6'h1a;
assign BITS_AC_0_3[0][12]= 6'h19;
assign BITS_AC_0_3[0][13]= 6'h18;
assign BITS_AC_0_3[0][14]= 6'h17;
assign BITS_AC_0_3[0][15]= 6'h1f;
assign BITS_AC_0_3[0][16]= 6'h1e;
assign BITS_AC_0_3[0][17]= 6'h1d;
assign BITS_AC_0_3[0][18]= 6'h1c;
assign BITS_AC_0_3[0][19]= 6'h1b;
assign BITS_AC_0_3[0][20]= 6'h1a;
assign BITS_AC_0_3[0][21]= 6'h19;
assign BITS_AC_0_3[0][22]= 6'h18;
assign BITS_AC_0_3[0][23]= 6'h17;
assign BITS_AC_0_3[0][24]= 6'h16;
assign BITS_AC_0_3[0][25]= 6'h15;
assign BITS_AC_0_3[0][26]= 6'h14;
assign BITS_AC_0_3[0][27]= 6'h13;
assign BITS_AC_0_3[0][28]= 6'h12;
assign BITS_AC_0_3[0][29]= 6'h11;
assign BITS_AC_0_3[0][30]= 6'h10;
assign BITS_AC_0_3[0][31]= 6'h18;
assign BITS_AC_0_3[0][32]= 6'h17;
assign BITS_AC_0_3[0][33]= 6'h16;
assign BITS_AC_0_3[0][34]= 6'h15;
assign BITS_AC_0_3[0][35]= 6'h14;
assign BITS_AC_0_3[0][36]= 6'h13;
assign BITS_AC_0_3[0][37]= 6'h12;
assign BITS_AC_0_3[0][38]= 6'h11;
assign BITS_AC_0_3[0][39]= 6'h10;
//  '{6'h03, 6'h06, 6'h25, 6'h0c, 6'h1b, 6'h16, 6'h15, 6'h1f, 6'h1e, 6'h1d, 6'h1c, 6'h1b, 6'h1a, 6'h19, 6'h13, 6'h12, 6'h11, 6'h10, 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 , 6'h0 },    // runlen=1 , absvm1<18
assign BITS_AC_0_3[1][0] = 6'h03;
assign BITS_AC_0_3[1][1] = 6'h06;
assign BITS_AC_0_3[1][2] = 6'h25;
assign BITS_AC_0_3[1][3] = 6'h0c;
assign BITS_AC_0_3[1][4] = 6'h1b;
assign BITS_AC_0_3[1][5] = 6'h16;
assign BITS_AC_0_3[1][6] = 6'h15;
assign BITS_AC_0_3[1][7] = 6'h1f;
assign BITS_AC_0_3[1][8] = 6'h1e;
assign BITS_AC_0_3[1][9] = 6'h1d;
assign BITS_AC_0_3[1][10]= 6'h1c;
assign BITS_AC_0_3[1][11]= 6'h1b;
assign BITS_AC_0_3[1][12]= 6'h1a;
assign BITS_AC_0_3[1][13]= 6'h19;
assign BITS_AC_0_3[1][14]= 6'h13;
assign BITS_AC_0_3[1][15]= 6'h12;
assign BITS_AC_0_3[1][16]= 6'h11;
assign BITS_AC_0_3[1][17]= 6'h10;
assign BITS_AC_0_3[1][18]= 6'h00;
assign BITS_AC_0_3[1][19]= 6'h00;
assign BITS_AC_0_3[1][20]= 6'h00;
assign BITS_AC_0_3[1][21]= 6'h00;
assign BITS_AC_0_3[1][22]= 6'h00;
assign BITS_AC_0_3[1][23]= 6'h00;
assign BITS_AC_0_3[1][24]= 6'h00;
assign BITS_AC_0_3[1][25]= 6'h00;
assign BITS_AC_0_3[1][26]= 6'h00;
assign BITS_AC_0_3[1][27]= 6'h00;
assign BITS_AC_0_3[1][28]= 6'h00;
assign BITS_AC_0_3[1][29]= 6'h00;
assign BITS_AC_0_3[1][30]= 6'h00;
assign BITS_AC_0_3[1][31]= 6'h00;
assign BITS_AC_0_3[1][32]= 6'h00;
assign BITS_AC_0_3[1][33]= 6'h00;
assign BITS_AC_0_3[1][34]= 6'h00;
assign BITS_AC_0_3[1][35]= 6'h00;
assign BITS_AC_0_3[1][36]= 6'h00;
assign BITS_AC_0_3[1][37]= 6'h00;
assign BITS_AC_0_3[1][38]= 6'h00;
assign BITS_AC_0_3[1][39]= 6'h00;

assign BITS_AC_0_3[2][0] = 6'h05;
assign BITS_AC_0_3[2][1] = 6'h04;
assign BITS_AC_0_3[2][2] = 6'h0b;
assign BITS_AC_0_3[2][3] = 6'h14;
assign BITS_AC_0_3[2][4] = 6'h14;
assign BITS_AC_0_3[2][5] = 6'h00;
assign BITS_AC_0_3[2][6] = 6'h00;
assign BITS_AC_0_3[2][7] = 6'h00;
assign BITS_AC_0_3[2][8] = 6'h00;
assign BITS_AC_0_3[2][9] = 6'h00;
assign BITS_AC_0_3[2][10]= 6'h00;
assign BITS_AC_0_3[2][11]= 6'h00;
assign BITS_AC_0_3[2][12]= 6'h00;
assign BITS_AC_0_3[2][13]= 6'h00;
assign BITS_AC_0_3[2][14]= 6'h00;
assign BITS_AC_0_3[2][15]= 6'h00;
assign BITS_AC_0_3[2][16]= 6'h00;
assign BITS_AC_0_3[2][17]= 6'h00;
assign BITS_AC_0_3[2][18]= 6'h00;
assign BITS_AC_0_3[2][19]= 6'h00;
assign BITS_AC_0_3[2][20]= 6'h00;
assign BITS_AC_0_3[2][21]= 6'h00;
assign BITS_AC_0_3[2][22]= 6'h00;
assign BITS_AC_0_3[2][23]= 6'h00;
assign BITS_AC_0_3[2][24]= 6'h00;
assign BITS_AC_0_3[2][25]= 6'h00;
assign BITS_AC_0_3[2][26]= 6'h00;
assign BITS_AC_0_3[2][27]= 6'h00;
assign BITS_AC_0_3[2][28]= 6'h00;
assign BITS_AC_0_3[2][29]= 6'h00;
assign BITS_AC_0_3[2][30]= 6'h00;
assign BITS_AC_0_3[2][31]= 6'h00;
assign BITS_AC_0_3[2][32]= 6'h00;
assign BITS_AC_0_3[2][33]= 6'h00;
assign BITS_AC_0_3[2][34]= 6'h00;
assign BITS_AC_0_3[2][35]= 6'h00;
assign BITS_AC_0_3[2][36]= 6'h00;
assign BITS_AC_0_3[2][37]= 6'h00;
assign BITS_AC_0_3[2][38]= 6'h00;
assign BITS_AC_0_3[2][39]= 6'h00;

assign BITS_AC_0_3[3][0] = 6'h07;
assign BITS_AC_0_3[3][1] = 6'h24;
assign BITS_AC_0_3[3][2] = 6'h1c;
assign BITS_AC_0_3[3][3] = 6'h13;
assign BITS_AC_0_3[3][4] = 6'h00;
assign BITS_AC_0_3[3][5] = 6'h00;
assign BITS_AC_0_3[3][6] = 6'h00;
assign BITS_AC_0_3[3][7] = 6'h00;
assign BITS_AC_0_3[3][8] = 6'h00;
assign BITS_AC_0_3[3][9] = 6'h00;
assign BITS_AC_0_3[3][10]= 6'h00;
assign BITS_AC_0_3[3][11]= 6'h00;
assign BITS_AC_0_3[3][12]= 6'h00;
assign BITS_AC_0_3[3][13]= 6'h00;
assign BITS_AC_0_3[3][14]= 6'h00;
assign BITS_AC_0_3[3][15]= 6'h00;
assign BITS_AC_0_3[3][16]= 6'h00;
assign BITS_AC_0_3[3][17]= 6'h00;
assign BITS_AC_0_3[3][18]= 6'h00;
assign BITS_AC_0_3[3][19]= 6'h00;
assign BITS_AC_0_3[3][20]= 6'h00;
assign BITS_AC_0_3[3][21]= 6'h00;
assign BITS_AC_0_3[3][22]= 6'h00;
assign BITS_AC_0_3[3][23]= 6'h00;
assign BITS_AC_0_3[3][24]= 6'h00;
assign BITS_AC_0_3[3][25]= 6'h00;
assign BITS_AC_0_3[3][26]= 6'h00;
assign BITS_AC_0_3[3][27]= 6'h00;
assign BITS_AC_0_3[3][28]= 6'h00;
assign BITS_AC_0_3[3][29]= 6'h00;
assign BITS_AC_0_3[3][30]= 6'h00;
assign BITS_AC_0_3[3][31]= 6'h00;
assign BITS_AC_0_3[3][32]= 6'h00;
assign BITS_AC_0_3[3][33]= 6'h00;
assign BITS_AC_0_3[3][34]= 6'h00;
assign BITS_AC_0_3[3][35]= 6'h00;
assign BITS_AC_0_3[3][36]= 6'h00;
assign BITS_AC_0_3[3][37]= 6'h00;
assign BITS_AC_0_3[3][38]= 6'h00;
assign BITS_AC_0_3[3][39]= 6'h00;



//localparam logic [4:0] LENS_AC_0_3 [4][40] = '{
//  '{5'd02, 5'd04, 5'd05, 5'd07, 5'd08, 5'd08, 5'd10, 5'd12, 5'd12, 5'd12, 5'd12, 5'd13, 5'd13, 5'd13, 5'd13, 5'd14, 5'd14, 5'd14, 5'd14, 5'd14, 5'd14, 5'd14, 5'd14, 5'd14, 5'd14, 5'd14, 5'd14, 5'd14, 5'd14, 5'd14, 5'd14, 5'd15, 5'd15, 5'd15, 5'd15, 5'd15, 5'd15, 5'd15, 5'd15, 5'd15},
//  '{5'd03, 5'd06, 5'd08, 5'd10, 5'd12, 5'd13, 5'd13, 5'd15, 5'd15, 5'd15, 5'd15, 5'd15, 5'd15, 5'd15, 5'd16, 5'd16, 5'd16, 5'd16, 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 },
//  '{5'd04, 5'd07, 5'd10, 5'd12, 5'd13, 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 },
//  '{5'd05, 5'd08, 5'd12, 5'd13, 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 }
//};

wire [4:0] LENS_AC_0_3 [0:3][0:39];

assign LENS_AC_0_3[0][0] = 5'd02;
assign LENS_AC_0_3[0][1] = 5'd04;
assign LENS_AC_0_3[0][2] = 5'd05;
assign LENS_AC_0_3[0][3] = 5'd07;
assign LENS_AC_0_3[0][4] = 5'd08;
assign LENS_AC_0_3[0][5] = 5'd08;
assign LENS_AC_0_3[0][6] = 5'd10;
assign LENS_AC_0_3[0][7] = 5'd12;
assign LENS_AC_0_3[0][8] = 5'd12;
assign LENS_AC_0_3[0][9] = 5'd12;
assign LENS_AC_0_3[0][10]= 5'd12;
assign LENS_AC_0_3[0][11]= 5'd13;
assign LENS_AC_0_3[0][12]= 5'd13;
assign LENS_AC_0_3[0][13]= 5'd13;
assign LENS_AC_0_3[0][14]= 5'd13;
assign LENS_AC_0_3[0][15]= 5'd14;
assign LENS_AC_0_3[0][16]= 5'd14;
assign LENS_AC_0_3[0][17]= 5'd14;
assign LENS_AC_0_3[0][18]= 5'd14;
assign LENS_AC_0_3[0][19]= 5'd14;
assign LENS_AC_0_3[0][20]= 5'd14;
assign LENS_AC_0_3[0][21]= 5'd14;
assign LENS_AC_0_3[0][22]= 5'd14;
assign LENS_AC_0_3[0][23]= 5'd14;
assign LENS_AC_0_3[0][24]= 5'd14;
assign LENS_AC_0_3[0][25]= 5'd14;
assign LENS_AC_0_3[0][26]= 5'd14;
assign LENS_AC_0_3[0][27]= 5'd14;
assign LENS_AC_0_3[0][28]= 5'd14;
assign LENS_AC_0_3[0][29]= 5'd14;
assign LENS_AC_0_3[0][30]= 5'd14;
assign LENS_AC_0_3[0][31]= 5'd15;
assign LENS_AC_0_3[0][32]= 5'd15;
assign LENS_AC_0_3[0][33]= 5'd15;
assign LENS_AC_0_3[0][34]= 5'd15;
assign LENS_AC_0_3[0][35]= 5'd15;
assign LENS_AC_0_3[0][36]= 5'd15;
assign LENS_AC_0_3[0][37]= 5'd15;
assign LENS_AC_0_3[0][38]= 5'd15;
assign LENS_AC_0_3[0][39]= 5'd15;
// '{5'd03, 5'd06, 5'd08, 5'd10, 5'd12, 5'd13, 5'd13, 5'd15, 5'd15, 5'd15, 5'd15, 5'd15, 5'd15, 5'd15, 5'd16, 5'd16, 5'd16, 5'd16, 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 , 5'd0 },
assign LENS_AC_0_3[1][0] = 5'd03;
assign LENS_AC_0_3[1][1] = 5'd06;
assign LENS_AC_0_3[1][2] = 5'd08;
assign LENS_AC_0_3[1][3] = 5'd10;
assign LENS_AC_0_3[1][4] = 5'd12;
assign LENS_AC_0_3[1][5] = 5'd13;
assign LENS_AC_0_3[1][6] = 5'd13;
assign LENS_AC_0_3[1][7] = 5'd15;
assign LENS_AC_0_3[1][8] = 5'd15;
assign LENS_AC_0_3[1][9] = 5'd15;
assign LENS_AC_0_3[1][10]= 5'd15;
assign LENS_AC_0_3[1][11]= 5'd15;
assign LENS_AC_0_3[1][12]= 5'd15;
assign LENS_AC_0_3[1][13]= 5'd15;
assign LENS_AC_0_3[1][14]= 5'd16;
assign LENS_AC_0_3[1][15]= 5'd16;
assign LENS_AC_0_3[1][16]= 5'd16;
assign LENS_AC_0_3[1][17]= 5'd16;
assign LENS_AC_0_3[1][18]= 5'd0;
assign LENS_AC_0_3[1][19]= 5'd0;
assign LENS_AC_0_3[1][20]= 5'd0;
assign LENS_AC_0_3[1][21]= 5'd0;
assign LENS_AC_0_3[1][22]= 5'd0;
assign LENS_AC_0_3[1][23]= 5'd0;
assign LENS_AC_0_3[1][24]= 5'd0;
assign LENS_AC_0_3[1][25]= 5'd0;
assign LENS_AC_0_3[1][26]= 5'd0;
assign LENS_AC_0_3[1][27]= 5'd0;
assign LENS_AC_0_3[1][28]= 5'd0;
assign LENS_AC_0_3[1][29]= 5'd0;
assign LENS_AC_0_3[1][30]= 5'd0;
assign LENS_AC_0_3[1][31]= 5'd0;
assign LENS_AC_0_3[1][32]= 5'd0;
assign LENS_AC_0_3[1][33]= 5'd0;
assign LENS_AC_0_3[1][34]= 5'd0;
assign LENS_AC_0_3[1][35]= 5'd0;
assign LENS_AC_0_3[1][36]= 5'd0;
assign LENS_AC_0_3[1][37]= 5'd0;
assign LENS_AC_0_3[1][38]= 5'd0;
assign LENS_AC_0_3[1][39]= 5'd0;

assign LENS_AC_0_3[2][0] = 5'd04;
assign LENS_AC_0_3[2][1] = 5'd07;
assign LENS_AC_0_3[2][2] = 5'd10;
assign LENS_AC_0_3[2][3] = 5'd12;
assign LENS_AC_0_3[2][4] = 5'd13;
assign LENS_AC_0_3[2][5] = 5'd0;
assign LENS_AC_0_3[2][6] = 5'd0;
assign LENS_AC_0_3[2][7] = 5'd0;
assign LENS_AC_0_3[2][8] = 5'd0;
assign LENS_AC_0_3[2][9] = 5'd0;
assign LENS_AC_0_3[2][10]= 5'd0;
assign LENS_AC_0_3[2][11]= 5'd0;
assign LENS_AC_0_3[2][12]= 5'd0;
assign LENS_AC_0_3[2][13]= 5'd0;
assign LENS_AC_0_3[2][14]= 5'd0;
assign LENS_AC_0_3[2][15]= 5'd0;
assign LENS_AC_0_3[2][16]= 5'd0;
assign LENS_AC_0_3[2][17]= 5'd0;
assign LENS_AC_0_3[2][18]= 5'd0;
assign LENS_AC_0_3[2][19]= 5'd0;
assign LENS_AC_0_3[2][20]= 5'd0;
assign LENS_AC_0_3[2][21]= 5'd0;
assign LENS_AC_0_3[2][22]= 5'd0;
assign LENS_AC_0_3[2][23]= 5'd0;
assign LENS_AC_0_3[2][24]= 5'd0;
assign LENS_AC_0_3[2][25]= 5'd0;
assign LENS_AC_0_3[2][26]= 5'd0;
assign LENS_AC_0_3[2][27]= 5'd0;
assign LENS_AC_0_3[2][28]= 5'd0;
assign LENS_AC_0_3[2][29]= 5'd0;
assign LENS_AC_0_3[2][30]= 5'd0;
assign LENS_AC_0_3[2][31]= 5'd0;
assign LENS_AC_0_3[2][32]= 5'd0;
assign LENS_AC_0_3[2][33]= 5'd0;
assign LENS_AC_0_3[2][34]= 5'd0;
assign LENS_AC_0_3[2][35]= 5'd0;
assign LENS_AC_0_3[2][36]= 5'd0;
assign LENS_AC_0_3[2][37]= 5'd0;
assign LENS_AC_0_3[2][38]= 5'd0;
assign LENS_AC_0_3[2][39]= 5'd0;

assign LENS_AC_0_3[3][0] = 5'd05;
assign LENS_AC_0_3[3][1] = 5'd08;
assign LENS_AC_0_3[3][2] = 5'd12;
assign LENS_AC_0_3[3][3] = 5'd13;
assign LENS_AC_0_3[3][4] = 5'd0;
assign LENS_AC_0_3[3][5] = 5'd0;
assign LENS_AC_0_3[3][6] = 5'd0;
assign LENS_AC_0_3[3][7] = 5'd0;
assign LENS_AC_0_3[3][8] = 5'd0;
assign LENS_AC_0_3[3][9] = 5'd0;
assign LENS_AC_0_3[3][10]= 5'd0;
assign LENS_AC_0_3[3][11]= 5'd0;
assign LENS_AC_0_3[3][12]= 5'd0;
assign LENS_AC_0_3[3][13]= 5'd0;
assign LENS_AC_0_3[3][14]= 5'd0;
assign LENS_AC_0_3[3][15]= 5'd0;
assign LENS_AC_0_3[3][16]= 5'd0;
assign LENS_AC_0_3[3][17]= 5'd0;
assign LENS_AC_0_3[3][18]= 5'd0;
assign LENS_AC_0_3[3][19]= 5'd0;
assign LENS_AC_0_3[3][20]= 5'd0;
assign LENS_AC_0_3[3][21]= 5'd0;
assign LENS_AC_0_3[3][22]= 5'd0;
assign LENS_AC_0_3[3][23]= 5'd0;
assign LENS_AC_0_3[3][24]= 5'd0;
assign LENS_AC_0_3[3][25]= 5'd0;
assign LENS_AC_0_3[3][26]= 5'd0;
assign LENS_AC_0_3[3][27]= 5'd0;
assign LENS_AC_0_3[3][28]= 5'd0;
assign LENS_AC_0_3[3][29]= 5'd0;
assign LENS_AC_0_3[3][30]= 5'd0;
assign LENS_AC_0_3[3][31]= 5'd0;
assign LENS_AC_0_3[3][32]= 5'd0;
assign LENS_AC_0_3[3][33]= 5'd0;
assign LENS_AC_0_3[3][34]= 5'd0;
assign LENS_AC_0_3[3][35]= 5'd0;
assign LENS_AC_0_3[3][36]= 5'd0;
assign LENS_AC_0_3[3][37]= 5'd0;
assign LENS_AC_0_3[3][38]= 5'd0;
assign LENS_AC_0_3[3][39]= 5'd0;



// localparam logic [5:0] BITS_AC_4_31 [32][3] = '{
//   '{6'h0 , 6'h0 , 6'h0 },  //   runlen=0 , unused
//   '{6'h0 , 6'h0 , 6'h0 },  //   runlen=1 , unused
//   '{6'h0 , 6'h0 , 6'h0 },  //   runlen=2 , unused
//   '{6'h0 , 6'h0 , 6'h0 },  //   runlen=3 , unused
//   '{6'h06, 6'h0f, 6'h12},  //   runlen=4 , absvm1<3
//   '{6'h07, 6'h09, 6'h12},  //   runlen=5 , absvm1<3
//   '{6'h05, 6'h1e, 6'h14},  //   runlen=6 , absvm1<3
//   '{6'h04, 6'h15, 6'h0 },  //   runlen=7 , absvm1<2
//   '{6'h07, 6'h11, 6'h0 },  //   runlen=8 , absvm1<2
//   '{6'h05, 6'h11, 6'h0 },  //   runlen=9 , absvm1<2
//   '{6'h27, 6'h10, 6'h0 },  //   runlen=10, absvm1<2
//   '{6'h23, 6'h1a, 6'h0 },  //   runlen=11, absvm1<2
//   '{6'h22, 6'h19, 6'h0 },  //   runlen=12, absvm1<2
//   '{6'h20, 6'h18, 6'h0 },  //   runlen=13, absvm1<2
//   '{6'h0e, 6'h17, 6'h0 },  //   runlen=14, absvm1<2
//   '{6'h0d, 6'h16, 6'h0 },  //   runlen=15, absvm1<2
//   '{6'h08, 6'h15, 6'h0 },  //   runlen=16, absvm1<2
//   '{6'h1f, 6'h0 , 6'h0 },  //   runlen=17, absvm1<1
//   '{6'h1a, 6'h0 , 6'h0 },  //   runlen=18, absvm1<1
//   '{6'h19, 6'h0 , 6'h0 },  //   runlen=19, absvm1<1
//   '{6'h17, 6'h0 , 6'h0 },  //   runlen=20, absvm1<1
//   '{6'h16, 6'h0 , 6'h0 },  //   runlen=21, absvm1<1
//   '{6'h1f, 6'h0 , 6'h0 },  //   runlen=22, absvm1<1
//   '{6'h1e, 6'h0 , 6'h0 },  //   runlen=23, absvm1<1
//   '{6'h1d, 6'h0 , 6'h0 },  //   runlen=24, absvm1<1
//   '{6'h1c, 6'h0 , 6'h0 },  //   runlen=25, absvm1<1
//   '{6'h1b, 6'h0 , 6'h0 },  //   runlen=26, absvm1<1
//   '{6'h1f, 6'h0 , 6'h0 },  //   runlen=27, absvm1<1
//   '{6'h1e, 6'h0 , 6'h0 },  //   runlen=28, absvm1<1
//   '{6'h1d, 6'h0 , 6'h0 },  //   runlen=29, absvm1<1
//   '{6'h1c, 6'h0 , 6'h0 },  //   runlen=30, absvm1<1
//   '{6'h1b, 6'h0 , 6'h0 }   //   runlen=31, absvm1<1
// };

wire [5:0] BITS_AC_4_31 [0:31][0:2];

assign BITS_AC_4_31[0][0] = 6'h0;   assign BITS_AC_4_31[0][1] = 6'h0;   assign BITS_AC_4_31[0][2] = 6'h0;      // runlen=0 , unused
assign BITS_AC_4_31[1][0] = 6'h0;   assign BITS_AC_4_31[1][1] = 6'h0;   assign BITS_AC_4_31[1][2] = 6'h0;      // runlen=1 , unused
assign BITS_AC_4_31[2][0] = 6'h0;   assign BITS_AC_4_31[2][1] = 6'h0;   assign BITS_AC_4_31[2][2] = 6'h0;      // runlen=2 , unused
assign BITS_AC_4_31[3][0] = 6'h0;   assign BITS_AC_4_31[3][1] = 6'h0;   assign BITS_AC_4_31[3][2] = 6'h0;      // runlen=3 , unused
assign BITS_AC_4_31[4][0] = 6'h06;  assign BITS_AC_4_31[4][1] = 6'h0f;  assign BITS_AC_4_31[4][2] = 6'h12;     // runlen=4 , absvm1<3
assign BITS_AC_4_31[5][0] = 6'h07;  assign BITS_AC_4_31[5][1] = 6'h09;  assign BITS_AC_4_31[5][2] = 6'h12;     // runlen=5 , absvm1<3
assign BITS_AC_4_31[6][0] = 6'h05;  assign BITS_AC_4_31[6][1] = 6'h1e;  assign BITS_AC_4_31[6][2] = 6'h14;     // runlen=6 , absvm1<3
assign BITS_AC_4_31[7][0] = 6'h04;  assign BITS_AC_4_31[7][1] = 6'h15;  assign BITS_AC_4_31[7][2] = 6'h0 ;     // runlen=7 , absvm1<2
assign BITS_AC_4_31[8][0] = 6'h07;  assign BITS_AC_4_31[8][1] = 6'h11;  assign BITS_AC_4_31[8][2] = 6'h0 ;     // runlen=8 , absvm1<2
assign BITS_AC_4_31[9][0] = 6'h05;  assign BITS_AC_4_31[9][1] = 6'h11;  assign BITS_AC_4_31[9][2] = 6'h0 ;     // runlen=9 , absvm1<2
assign BITS_AC_4_31[10][0]= 6'h27;  assign BITS_AC_4_31[10][1]= 6'h10;  assign BITS_AC_4_31[10][2]= 6'h0 ;     // runlen=10, absvm1<2
assign BITS_AC_4_31[11][0]= 6'h23;  assign BITS_AC_4_31[11][1]= 6'h1a;  assign BITS_AC_4_31[11][2]= 6'h0 ;     // runlen=11, absvm1<2
assign BITS_AC_4_31[12][0]= 6'h22;  assign BITS_AC_4_31[12][1]= 6'h19;  assign BITS_AC_4_31[12][2]= 6'h0 ;     // runlen=12, absvm1<2
assign BITS_AC_4_31[13][0]= 6'h20;  assign BITS_AC_4_31[13][1]= 6'h18;  assign BITS_AC_4_31[13][2]= 6'h0 ;     // runlen=13, absvm1<2
assign BITS_AC_4_31[14][0]= 6'h0e;  assign BITS_AC_4_31[14][1]= 6'h17;  assign BITS_AC_4_31[14][2]= 6'h0 ;     // runlen=14, absvm1<2
assign BITS_AC_4_31[15][0]= 6'h0d;  assign BITS_AC_4_31[15][1]= 6'h16;  assign BITS_AC_4_31[15][2]= 6'h0 ;     // runlen=15, absvm1<2
assign BITS_AC_4_31[16][0]= 6'h08;  assign BITS_AC_4_31[16][1]= 6'h15;  assign BITS_AC_4_31[16][2]= 6'h0 ;     // runlen=16, absvm1<2
assign BITS_AC_4_31[17][0]= 6'h1f;  assign BITS_AC_4_31[17][1]= 6'h0 ;  assign BITS_AC_4_31[17][2]= 6'h0 ;     // runlen=17, absvm1<1
assign BITS_AC_4_31[18][0]= 6'h1a;  assign BITS_AC_4_31[18][1]= 6'h0 ;  assign BITS_AC_4_31[18][2]= 6'h0 ;     // runlen=18, absvm1<1
assign BITS_AC_4_31[19][0]= 6'h19;  assign BITS_AC_4_31[19][1]= 6'h0 ;  assign BITS_AC_4_31[19][2]= 6'h0 ;     // runlen=19, absvm1<1
assign BITS_AC_4_31[20][0]= 6'h17;  assign BITS_AC_4_31[20][1]= 6'h0 ;  assign BITS_AC_4_31[20][2]= 6'h0 ;     // runlen=20, absvm1<1
assign BITS_AC_4_31[21][0]= 6'h16;  assign BITS_AC_4_31[21][1]= 6'h0 ;  assign BITS_AC_4_31[21][2]= 6'h0 ;     // runlen=21, absvm1<1
assign BITS_AC_4_31[22][0]= 6'h1f;  assign BITS_AC_4_31[22][1]= 6'h0 ;  assign BITS_AC_4_31[22][2]= 6'h0 ;     // runlen=22, absvm1<1
assign BITS_AC_4_31[23][0]= 6'h1e;  assign BITS_AC_4_31[23][1]= 6'h0 ;  assign BITS_AC_4_31[23][2]= 6'h0 ;     // runlen=23, absvm1<1
assign BITS_AC_4_31[24][0]= 6'h1d;  assign BITS_AC_4_31[24][1]= 6'h0 ;  assign BITS_AC_4_31[24][2]= 6'h0 ;     // runlen=24, absvm1<1
assign BITS_AC_4_31[25][0]= 6'h1c;  assign BITS_AC_4_31[25][1]= 6'h0 ;  assign BITS_AC_4_31[25][2]= 6'h0 ;     // runlen=25, absvm1<1
assign BITS_AC_4_31[26][0]= 6'h1b;  assign BITS_AC_4_31[26][1]= 6'h0 ;  assign BITS_AC_4_31[26][2]= 6'h0 ;     // runlen=26, absvm1<1
assign BITS_AC_4_31[27][0]= 6'h1f;  assign BITS_AC_4_31[27][1]= 6'h0 ;  assign BITS_AC_4_31[27][2]= 6'h0 ;     // runlen=27, absvm1<1
assign BITS_AC_4_31[28][0]= 6'h1e;  assign BITS_AC_4_31[28][1]= 6'h0 ;  assign BITS_AC_4_31[28][2]= 6'h0 ;     // runlen=28, absvm1<1
assign BITS_AC_4_31[29][0]= 6'h1d;  assign BITS_AC_4_31[29][1]= 6'h0 ;  assign BITS_AC_4_31[29][2]= 6'h0 ;     // runlen=29, absvm1<1
assign BITS_AC_4_31[30][0]= 6'h1c;  assign BITS_AC_4_31[30][1]= 6'h0 ;  assign BITS_AC_4_31[30][2]= 6'h0 ;     // runlen=30, absvm1<1
assign BITS_AC_4_31[31][0]= 6'h1b;  assign BITS_AC_4_31[31][1]= 6'h0 ;  assign BITS_AC_4_31[31][2]= 6'h0 ;     // runlen=31, absvm1<1



// localparam logic [4:0] LENS_AC_4_31 [32][3] = '{
//   '{5'd0 , 5'd0 , 5'd0 },
//   '{5'd0 , 5'd0 , 5'd0 },
//   '{5'd0 , 5'd0 , 5'd0 },
//   '{5'd0 , 5'd0 , 5'd0 },
//   '{5'd05, 5'd10, 5'd12},
//   '{5'd06, 5'd10, 5'd13},
//   '{5'd06, 5'd12, 5'd16},
//   '{5'd06, 5'd12, 5'd0 },
//   '{5'd07, 5'd12, 5'd0 },
//   '{5'd07, 5'd13, 5'd0 },
//   '{5'd08, 5'd13, 5'd0 },
//   '{5'd08, 5'd16, 5'd0 },
//   '{5'd08, 5'd16, 5'd0 },
//   '{5'd08, 5'd16, 5'd0 },
//   '{5'd10, 5'd16, 5'd0 },
//   '{5'd10, 5'd16, 5'd0 },
//   '{5'd10, 5'd16, 5'd0 },
//   '{5'd12, 5'd0 , 5'd0 },
//   '{5'd12, 5'd0 , 5'd0 },
//   '{5'd12, 5'd0 , 5'd0 },
//   '{5'd12, 5'd0 , 5'd0 },
//   '{5'd12, 5'd0 , 5'd0 },
//   '{5'd13, 5'd0 , 5'd0 },
//   '{5'd13, 5'd0 , 5'd0 },
//   '{5'd13, 5'd0 , 5'd0 },
//   '{5'd13, 5'd0 , 5'd0 },
//   '{5'd13, 5'd0 , 5'd0 },
//   '{5'd16, 5'd0 , 5'd0 },
//   '{5'd16, 5'd0 , 5'd0 },
//   '{5'd16, 5'd0 , 5'd0 },
//   '{5'd16, 5'd0 , 5'd0 },
//   '{5'd16, 5'd0 , 5'd0 }
// };

wire [4:0] LENS_AC_4_31 [0:31][0:2];

assign LENS_AC_4_31[0][0] = 5'd0;   assign LENS_AC_4_31[0][1] = 5'd0;   assign LENS_AC_4_31[0][2] = 5'd0;      // runlen=0 , unused
assign LENS_AC_4_31[1][0] = 5'd0;   assign LENS_AC_4_31[1][1] = 5'd0;   assign LENS_AC_4_31[1][2] = 5'd0;      // runlen=1 , unused
assign LENS_AC_4_31[2][0] = 5'd0;   assign LENS_AC_4_31[2][1] = 5'd0;   assign LENS_AC_4_31[2][2] = 5'd0;      // runlen=2 , unused
assign LENS_AC_4_31[3][0] = 5'd0;   assign LENS_AC_4_31[3][1] = 5'd0;   assign LENS_AC_4_31[3][2] = 5'd0;      // runlen=3 , unused
assign LENS_AC_4_31[4][0] = 5'd05;  assign LENS_AC_4_31[4][1] = 5'd10;  assign LENS_AC_4_31[4][2] = 5'd12;     // runlen=4 , absvm1<3
assign LENS_AC_4_31[5][0] = 5'd06;  assign LENS_AC_4_31[5][1] = 5'd10;  assign LENS_AC_4_31[5][2] = 5'd13;     // runlen=5 , absvm1<3
assign LENS_AC_4_31[6][0] = 5'd06;  assign LENS_AC_4_31[6][1] = 5'd12;  assign LENS_AC_4_31[6][2] = 5'd16;     // runlen=6 , absvm1<3
assign LENS_AC_4_31[7][0] = 5'd06;  assign LENS_AC_4_31[7][1] = 5'd12;  assign LENS_AC_4_31[7][2] = 5'd0 ;     // runlen=7 , absvm1<2
assign LENS_AC_4_31[8][0] = 5'd07;  assign LENS_AC_4_31[8][1] = 5'd12;  assign LENS_AC_4_31[8][2] = 5'd0 ;     // runlen=8 , absvm1<2
assign LENS_AC_4_31[9][0] = 5'd07;  assign LENS_AC_4_31[9][1] = 5'd13;  assign LENS_AC_4_31[9][2] = 5'd0 ;     // runlen=9 , absvm1<2
assign LENS_AC_4_31[10][0]= 5'd08;  assign LENS_AC_4_31[10][1]= 5'd13;  assign LENS_AC_4_31[10][2]= 5'd0 ;     // runlen=10, absvm1<2
assign LENS_AC_4_31[11][0]= 5'd08;  assign LENS_AC_4_31[11][1]= 5'd16;  assign LENS_AC_4_31[11][2]= 5'd0 ;     // runlen=11, absvm1<2
assign LENS_AC_4_31[12][0]= 5'd08;  assign LENS_AC_4_31[12][1]= 5'd16;  assign LENS_AC_4_31[12][2]= 5'd0 ;     // runlen=12, absvm1<2
assign LENS_AC_4_31[13][0]= 5'd08;  assign LENS_AC_4_31[13][1]= 5'd16;  assign LENS_AC_4_31[13][2]= 5'd0 ;     // runlen=13, absvm1<2
assign LENS_AC_4_31[14][0]= 5'd10;  assign LENS_AC_4_31[14][1]= 5'd16;  assign LENS_AC_4_31[14][2]= 5'd0 ;     // runlen=14, absvm1<2
assign LENS_AC_4_31[15][0]= 5'd10;  assign LENS_AC_4_31[15][1]= 5'd16;  assign LENS_AC_4_31[15][2]= 5'd0 ;     // runlen=15, absvm1<2
assign LENS_AC_4_31[16][0]= 5'd10;  assign LENS_AC_4_31[16][1]= 5'd16;  assign LENS_AC_4_31[16][2]= 5'd0 ;     // runlen=16, absvm1<2
assign LENS_AC_4_31[17][0]= 5'd12;  assign LENS_AC_4_31[17][1]= 5'd0 ;  assign LENS_AC_4_31[17][2]= 5'd0 ;     // runlen=17, absvm1<1
assign LENS_AC_4_31[18][0]= 5'd12;  assign LENS_AC_4_31[18][1]= 5'd0 ;  assign LENS_AC_4_31[18][2]= 5'd0 ;     // runlen=18, absvm1<1
assign LENS_AC_4_31[19][0]= 5'd12;  assign LENS_AC_4_31[19][1]= 5'd0 ;  assign LENS_AC_4_31[19][2]= 5'd0 ;     // runlen=19, absvm1<1
assign LENS_AC_4_31[20][0]= 5'd12;  assign LENS_AC_4_31[20][1]= 5'd0 ;  assign LENS_AC_4_31[20][2]= 5'd0 ;     // runlen=20, absvm1<1
assign LENS_AC_4_31[21][0]= 5'd12;  assign LENS_AC_4_31[21][1]= 5'd0 ;  assign LENS_AC_4_31[21][2]= 5'd0 ;     // runlen=21, absvm1<1
assign LENS_AC_4_31[22][0]= 5'd13;  assign LENS_AC_4_31[22][1]= 5'd0 ;  assign LENS_AC_4_31[22][2]= 5'd0 ;     // runlen=22, absvm1<1
assign LENS_AC_4_31[23][0]= 5'd13;  assign LENS_AC_4_31[23][1]= 5'd0 ;  assign LENS_AC_4_31[23][2]= 5'd0 ;     // runlen=23, absvm1<1
assign LENS_AC_4_31[24][0]= 5'd13;  assign LENS_AC_4_31[24][1]= 5'd0 ;  assign LENS_AC_4_31[24][2]= 5'd0 ;     // runlen=24, absvm1<1
assign LENS_AC_4_31[25][0]= 5'd13;  assign LENS_AC_4_31[25][1]= 5'd0 ;  assign LENS_AC_4_31[25][2]= 5'd0 ;     // runlen=25, absvm1<1
assign LENS_AC_4_31[26][0]= 5'd13;  assign LENS_AC_4_31[26][1]= 5'd0 ;  assign LENS_AC_4_31[26][2]= 5'd0 ;     // runlen=26, absvm1<1
assign LENS_AC_4_31[27][0]= 5'd16;  assign LENS_AC_4_31[27][1]= 5'd0 ;  assign LENS_AC_4_31[27][2]= 5'd0 ;     // runlen=27, absvm1<1
assign LENS_AC_4_31[28][0]= 5'd16;  assign LENS_AC_4_31[28][1]= 5'd0 ;  assign LENS_AC_4_31[28][2]= 5'd0 ;     // runlen=28, absvm1<1
assign LENS_AC_4_31[29][0]= 5'd16;  assign LENS_AC_4_31[29][1]= 5'd0 ;  assign LENS_AC_4_31[29][2]= 5'd0 ;     // runlen=29, absvm1<1
assign LENS_AC_4_31[30][0]= 5'd16;  assign LENS_AC_4_31[30][1]= 5'd0 ;  assign LENS_AC_4_31[30][2]= 5'd0 ;     // runlen=30, absvm1<1
assign LENS_AC_4_31[31][0]= 5'd16;  assign LENS_AC_4_31[31][1]= 5'd0 ;  assign LENS_AC_4_31[31][2]= 5'd0 ;     // runlen=31, absvm1<1






//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// functions
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

function  [7:0] mean2;
    input [7:0] a, b;
    reg   [8:0] tmp;
begin
    tmp = 9'd1 + {1'b0,a} + {1'b0,b};
    mean2 = tmp[8:1];
end
endfunction


function  [7:0] mean4;
    input [7:0] a, b, c, d;
    reg   [9:0] tmp;
begin
    tmp = 10'd1 + {2'b0,a} + {2'b0,b} + {2'b0,c} + {2'b0,d};
    mean4 = tmp[9:2];
end
endfunction


function  [7:0] func_diff;
    input [7:0] a, b;
begin
    func_diff = (a>b) ? (a-b) : (b-a);
end
endfunction


function  signed [ 8:0] clip_neg255_pos255;
    input signed [27:0] x;
begin
    clip_neg255_pos255 = (x < -28'sd255) ? -9'sd255 : (x > 28'sd255) ? 9'sd255 : x[8:0] ;
end
endfunction


function         [7:0] add_clip_0_255;
    input        [7:0] a;
    input signed [8:0] b;
    reg   signed [9:0] c;
begin
    c = b;
    c = c + $signed( {2'b0, a} );
    add_clip_0_255 = (c > 10'sd255) ? 8'd255 : (c < 10'sd0) ? 8'd0 : c[7:0] ;
end
endfunction

//function automatic logic [7:0] add_clip_0_255 (input logic [7:0] a, input logic signed [8:0] b);
//    logic [9:0] c = b;
//    c += $signed( (10)'(a) );
//    return (c > 10'sd255) ? 8'd255 : (c < 10'sd0) ? 8'd0 : (8)'( $unsigned(c) ) ;
//endfunction


function  [ 3:0] find_min_in_10_values;
    input [12:0] v0, v1, v2, v3, v4, v5, v6, v7, v8, v9;
//function automatic logic [3:0] find_min_in_10_values (input logic [12:0] v0, input logic [12:0] v1, input logic [12:0] v2, input logic [12:0] v3, input logic [12:0] v4, input logic [12:0] v5, input logic [12:0] v6, input logic [12:0] v7, input logic [12:0] v8, input logic [12:0] v9 );
    reg        wi1, wi3, wi5, wi7, wi9;
    reg [12:0] w01, w23, w45, w67, w89;
    reg        xi23,      xi67;
    reg [12:0] x0123,    x4567;
begin
    wi1 =       v1 < v0;
    w01 = wi1 ? v1 : v0;
    wi3 =       v3 < v2;
    w23 = wi3 ? v3 : v2;
    wi5 =       v5 < v4;
    w45 = wi5 ? v5 : v4;
    wi7 =       v7 < v6;
    w67 = wi7 ? v7 : v6;
    wi9 =       v9 < v8;
    w89 = wi9 ? v9 : v8;
    xi23  =        w23 < w01;
    x0123 = xi23 ? w23 : w01;
    xi67  =        w67 < w45;
    x4567 = xi67 ? w67 : w45;
    if( w89 <= x0123 && w89 <= x4567) begin
        find_min_in_10_values = {3'b100, wi9};
    end else if(x0123 < x4567) begin
        if( xi23 )
            find_min_in_10_values = {3'b001, wi3};
        else
            find_min_in_10_values = {3'b000, wi1};
    end else begin
        if( xi67 )
            find_min_in_10_values = {3'b011, wi7};
        else
            find_min_in_10_values = {3'b010, wi5};
    end
end
endfunction


// inverse two dimensional DCT (Chen-Wang algorithm) stage 1: right multiply a matrix, act on each rows
function  [32*9-1:0] invserse_dct_rows_step12;
    input signed [12:0] a0, a1, a2, a3, a4, a5, a6, a7;
//function automatic logic [32*9-1:0] invserse_dct_rows_step12 (input logic signed [12:0] a0, input logic signed [12:0] a1, input logic signed [12:0] a2, input logic signed [12:0] a3, input logic signed [12:0] a4, input logic signed [12:0] a5, input logic signed [12:0] a6, input logic signed [12:0] a7 );
    reg   signed [31:0] x0, x1, x2, x3, x4, x5, x6, x7, x8;
begin
    x0 = a0;
    x1 = a4;
    x2 = a6;
    x3 = a2;
    x4 = a1;
    x5 = a7;
    x6 = a5;
    x7 = a3;
    x0 = x0 << 11;
    x1 = x1 << 11;
    x0[7] = 1'b1;                // x0 += 128 , for proper rounding in the fourth stage
    // step 1 ----------------------------------------------------------------------------------
    x8 = W7 * (x4+x5);
    x4 = x8 + (W1-W7) * x4;
    x5 = x8 - (W1+W7) * x5;
    x8 = W3 * (x6+x7);
    x6 = x8 - (W3-W5) * x6;
    x7 = x8 - (W3+W5) * x7;
    // step 2 ----------------------------------------------------------------------------------
    x8 = x0 + x1;
    x0 = x0 - x1;
    x1 = W6 * (x3+x2);
    x2 = x1 - (W2+W6) * x2;
    x3 = x1 + (W2-W6) * x3;
    x1 = x4 + x6;
    x4 = x4 - x6;
    x6 = x5 + x7;
    x5 = x5 - x7;
    invserse_dct_rows_step12 = {x0, x1, x2, x3, x4, x5, x6, x7, x8};
end
endfunction


function  [18*8-1:0] invserse_dct_rows_step34;
    input [32*9-1:0] x0_to_x8;
//function automatic logic [18*8-1:0] invserse_dct_rows_step34 (logic [32*9-1:0] x0_to_x8);
    reg signed [31:0] x0, x1, x2, x3, x4, x5, x6, x7, x8;
    reg        [17:0] r0, r1, r2, r3, r4, r5, r6, r7;
begin
    {x0, x1, x2, x3, x4, x5, x6, x7, x8} = x0_to_x8;
    // step 3 ----------------------------------------------------------------------------------
    x7 = x8 + x3;
    x8 = x8 - x3;
    x3 = x0 + x2;
    x0 = x0 - x2;
    x2 = (32'sd181 * (x4+x5) + 32'sd128) >>> 8;
    x4 = (32'sd181 * (x4-x5) + 32'sd128) >>> 8;
    // step 4 ----------------------------------------------------------------------------------
    r0 = ( (x7 + x1) >>> 8 );
    r1 = ( (x3 + x2) >>> 8 );
    r2 = ( (x0 + x4) >>> 8 );
    r3 = ( (x8 + x6) >>> 8 );
    r4 = ( (x8 - x6) >>> 8 );
    r5 = ( (x0 - x4) >>> 8 );
    r6 = ( (x3 - x2) >>> 8 );
    r7 = ( (x7 - x1) >>> 8 );
    invserse_dct_rows_step34 = {r0, r1, r2, r3, r4, r5, r6, r7};
end
endfunction


// inverse two dimensional DCT (Chen-Wang algorithm) stage 2: left multiply a matrix, act on each columns
function [32*9-1:0] invserse_dct_cols_step12;
    input signed [17:0] a0, a1, a2, a3, a4, a5, a6, a7;
//function automatic logic [32*9-1:0] invserse_dct_cols_step12 (input logic signed [17:0] a0, input logic signed [17:0] a1, input logic signed [17:0] a2, input logic signed [17:0] a3, input logic signed [17:0] a4, input logic signed [17:0] a5, input logic signed [17:0] a6, input logic signed [17:0] a7 );
    reg   signed [31:0] x0, x1, x2, x3, x4, x5, x6, x7, x8;
begin
    x0 = a0;
    x1 = a4;
    x2 = a6;
    x3 = a2;
    x4 = a1;
    x5 = a7;
    x6 = a5;
    x7 = a3;
    x0 = x0 << 8;
    x1 = x1 << 8;
    x0 = x0 + 32'sd8192;
    // step 1 ----------------------------------------------------------------------------------
    x8 = W7 * (x4+x5) + 32'sd4;
    x4 = (x8 + (W1-W7) * x4) >>> 3;
    x5 = (x8 - (W1+W7) * x5) >>> 3;
    x8 = W3 * (x6+x7) + 32'sd4;
    x6 = (x8 - (W3-W5) * x6) >>> 3;
    x7 = (x8 - (W3+W5) * x7) >>>3;
    // step 2 ----------------------------------------------------------------------------------
    x8 = x0 + x1;
    x0 = x0 - x1;
    x1 = W6 * (x3+x2) + 32'sd4;
    x2 = (x1 - (W2+W6) * x2) >>> 3;
    x3 = (x1 + (W2-W6) * x3) >>> 3;
    x1 = x4 + x6;
    x4 = x4 - x6;
    x6 = x5 + x7;
    x5 = x5 - x7;
    invserse_dct_cols_step12 = {x0, x1, x2, x3, x4, x5, x6, x7, x8};
end
endfunction


function  [ 9*8-1:0] invserse_dct_cols_step34;
    input [32*9-1:0] x0_to_x8;
//function automatic logic [9*8-1:0] invserse_dct_cols_step34(input logic [32*9-1:0] x0_to_x8);
    reg signed [31:0] x0, x1, x2, x3, x4, x5, x6, x7, x8;
begin
    {x0, x1, x2, x3, x4, x5, x6, x7, x8} = x0_to_x8;
    // step 3 ----------------------------------------------------------------------------------
    x7 = x8 + x3;
    x8 = x8 - x3;
    x3 = x0 + x2;
    x0 = x0 - x2;
    x2 = (32'sd181 * (x4+x5) + 32'sd128) >>> 8;
    x4 = (32'sd181 * (x4-x5) + 32'sd128) >>> 8;
    // step 4 ----------------------------------------------------------------------------------
    invserse_dct_cols_step34 = { clip_neg255_pos255( (x7+x1) >>> 14 ),
                                 clip_neg255_pos255( (x3+x2) >>> 14 ),
                                 clip_neg255_pos255( (x0+x4) >>> 14 ),
                                 clip_neg255_pos255( (x8+x6) >>> 14 ),
                                 clip_neg255_pos255( (x8-x6) >>> 14 ),
                                 clip_neg255_pos255( (x0-x4) >>> 14 ),
                                 clip_neg255_pos255( (x3-x2) >>> 14 ),
                                 clip_neg255_pos255( (x7-x1) >>> 14 ) };
end
endfunction





//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// stage A : overall control, horizontal U/V subsample
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// overall configuration variables
reg          [       7:0] pframes_count;

wire         [  XB16-1:0] i_max_x16 = ( i_xsize16 > (1<<XL) )  ?  ((1<<XL)-1)     :       // i_xsize16 larger than the upper bound
                                      ( i_xsize16 < (4)     )  ?  (3)             :       // i_xsize16 smaller than the lower bound
                                                                  (i_xsize16 - 1) ;       // 

wire         [  YB16-1:0] i_max_y16 = ( i_ysize16 > (1<<YL) )  ?  ((1<<YL)-1)     :       // i_ysize16 larger than the upper bound
                                      ( i_ysize16 < (4)     )  ?  (3)             :       // i_ysize16 smaller than the lower bound
                                                                  (i_ysize16 - 1) ;       //

reg          [  XB16-1:0] max_x16;
reg          [  YB16-1:0] max_y16;

wire         [  XB8 -1:0] max_x8 = {max_x16, 1'b1};
wire         [  YB8 -1:0] max_y8 = {max_y16, 1'b1};
wire         [  XB4 -1:0] max_x4 = {max_x8 , 1'b1};
wire         [  YB4 -1:0] max_y4 = {max_y8 , 1'b1};
wire         [  XB2 -1:0] max_x2 = {max_x4 , 1'b1};
wire         [  YB2 -1:0] max_y2 = {max_y4 , 1'b1};
wire         [  XB  -1:0] max_x  = {max_x2 , 1'b1};
wire         [  YB  -1:0] max_y  = {max_y2 , 1'b1};

wire         [      11:0] size_x = max_x + 1;
wire         [      11:0] size_y = max_y + 1;

reg          [       7:0] a_i_frame;                                         // frame index in current GOP
reg          [   XB4-1:0] a_x4;
reg          [   YB -1:0] a_y ;
reg                       a_en;
reg          [       7:0] a_Y0, a_Y1, a_Y2, a_Y3;
reg          [       7:0] a_U0, a_U2, a_V0, a_V2;

reg                       sequence_start;

localparam   [       1:0] SEQ_IDLE   = 2'd0,
                          SEQ_DURING = 2'd1,
                          SEQ_ENDING = 2'd2,
                          SEQ_ENDED  = 2'd3;

reg          [       1:0] sequence_state = SEQ_IDLE;

//enum reg     [       1:0] {SEQ_IDLE, SEQ_DURING, SEQ_ENDING, SEQ_ENDED} sequence_state;

// overall control FSM of video sequence -------------------------------------------------------------
always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        pframes_count <= 8'd0;
        max_x16 <= 0;
        max_y16 <= 0;
        a_i_frame <= 8'd0;
        a_x4 <= 0;
        a_y  <= 0;
        a_en <= 1'b0;
        {a_Y0, a_Y1, a_Y2, a_Y3} <= {8'h00, 8'h00, 8'h00, 8'h00};                                                      // default : black pixels
        {a_U0, a_U2, a_V0, a_V2} <= {8'h80, 8'h80, 8'h80, 8'h80};                                                      // default : black pixels
        sequence_start <= 1'b0;
        sequence_state <= SEQ_IDLE;
    end else begin                                                                                                     //
        sequence_start <= 1'b0;
        a_en <= 1'b0;                                                                                                  // default : don't transmit pixels
        {a_Y0, a_Y1, a_Y2, a_Y3} <= {8'h00, 8'h00, 8'h00, 8'h00};                                                      // default : black pixels
        {a_U0, a_U2, a_V0, a_V2} <= {8'h80, 8'h80, 8'h80, 8'h80};                                                      // default : black pixels
        if( sequence_state == SEQ_ENDED ) begin                                                                        // 
            if (o_last)
                sequence_state <= SEQ_IDLE;
        end else if( sequence_state == SEQ_ENDING ) begin                                                              // user required to stop the current sequence.
            if( a_x4 < max_x4 ) begin                                                                                  //   the current frame has not ended yet.
                a_x4 <= a_x4 + 1;                                                                                      //
                a_en <= 1'b1;                                                                                          //     transmit black pixels to fill the un-ended frame
            end else if( a_y < max_y ) begin                                                                           //   the current frame has not ended yet.
                a_x4 <= 0;                                                                                            //
                a_y <= a_y + 1;                                                                                        //
                a_en <= 1'b1;                                                                                          //     transmit black pixels to fill the un-ended frame
            end else begin                                                                                             //   the current frame has already ended.
                sequence_state <= SEQ_ENDED; ////////////////////////////////////////////////////////////              //     TODO: wait for the output stream's end, then let sequence_state<=SEQ_IDLE
            end                                                                                                        //
        end else if( i_en ) begin                                                                                      // user input a cycle of pixels
            if( sequence_state == SEQ_IDLE ) begin                                                                     //   if the video sequence is not yet started (i.e., this is the first cycle of a new video sequence)
                sequence_state <= SEQ_DURING;                                                                          //     start the video sequence
                sequence_start <= 1'b1;
                pframes_count <= i_pframes_count;                                                                      //     load configuration for the new video sequence
                max_x16 <= i_max_x16;                                                                                  //     load configuration for the new video sequence
                max_y16 <= i_max_y16;                                                                                  //     load configuration for the new video sequence
                a_x4 = 0;                                                                                              //     reset index
                a_y  = 0;                                                                                              //     reset index
                a_i_frame <= 8'd0;                                                                                     //     reset index
            end else begin                                                                                             //   if the video sequence is already started
                if( a_x4 < max_x4 ) begin                                                                              //     update index
                    a_x4 <= a_x4 + 1;                                                                                  //
                end else begin                                                                                         //
                    a_x4 <= 0;                                                                                         //
                    if( a_y < max_y ) begin                                                                            //
                        a_y <= a_y + 1;                                                                                //
                    end else begin                                                                                     //
                        a_y <= 0;                                                                                      //
                        a_i_frame <= (a_i_frame < pframes_count) ? a_i_frame + 8'd1 : 8'd0;                            //
                    end                                                                                                //
                end                                                                                                    //
            end                                                                                                        //
            if( i_sequence_stop )                                                                                      //   user want to stop the current sequence
                sequence_state <= SEQ_ENDING;                                                                          //
            a_en <= 1'b1;                                                                                              //   transmit the user-inputted pixels
            {a_Y0, a_Y1, a_Y2, a_Y3} <= {i_Y0, i_Y1, i_Y2, i_Y3};                                                      //   Y
            a_U0 <= mean2(i_U0, i_U1);                                                                                 //   U0, U1 horizontal subsample to U0
            a_U2 <= mean2(i_U2, i_U3);                                                                                 //   U2, U3 horizontal subsample to U2
            a_V0 <= mean2(i_V0, i_V1);                                                                                 //   V0, V1 horizontal subsample to V0
            a_V2 <= mean2(i_V2, i_V3);                                                                                 //   V2, V3 horizontal subsample to V2
        end else if( i_sequence_stop && sequence_state == SEQ_DURING ) begin                                           // user want to stop the current sequence
            sequence_state <= SEQ_ENDING;                                                                              //
        end                                                                                                            //
    end                                                                                                                //

assign o_sequence_busy = (sequence_state != SEQ_IDLE) ;





//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// stage B & C : Use line-buffer to vertical subsample U/V, convert to YUV 4:2:0
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg          [   2*8-1:0] mem_lbuf_U [0 : ((XSIZE/4)-1)];                   // U line buffer: XSIZE/4 items, each item contains 2 U pixels
reg          [   2*8-1:0] mem_lbuf_V [0 : ((XSIZE/4)-1)];                   // V line buffer: XSIZE/4 items, each item contains 2 V pixels

reg          [       7:0] b_i_frame;
reg          [   XB4-1:0] b_x4;
reg          [   YB -1:0] b_y ;
reg                       b_en;
reg          [       7:0] b_Y0, b_Y1, b_Y2, b_Y3;
reg          [       7:0] b_U0, b_U2, b_V0, b_V2;
reg          [       7:0] b_U0_u, b_U2_u, b_V0_u, b_V2_u;                   // readout U/V in upper row (previous row) from line-buffer. Not a real register

always @ (posedge clk)                                                      // write line-buffer
    if( a_en ) begin
        mem_lbuf_U[a_x4] <= {a_U0, a_U2};
        mem_lbuf_V[a_x4] <= {a_V0, a_V2};
    end

always @ (posedge clk) begin                                                // read line-buffer
    {b_U0_u, b_U2_u} <= mem_lbuf_U[a_x4];
    {b_V0_u, b_V2_u} <= mem_lbuf_V[a_x4];
end

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        b_i_frame <= 8'd0;
        b_x4 <= 0;
        b_y  <= 0;
        b_en <= 1'b0;
    end else begin
        b_i_frame <= a_i_frame;
        b_x4 <= a_x4;
        b_y  <= a_y;
        b_en <= a_en;
    end

always @ (posedge clk) begin
    {b_Y0, b_Y1, b_Y2, b_Y3} <= {a_Y0, a_Y1, a_Y2, a_Y3};
    {b_U0, b_U2, b_V0, b_V2} <= {a_U0, a_U2, a_V0, a_V2};
end

reg          [       7:0] c_i_frame;
reg          [   XB4-1:0] c_x4;
reg          [   YB -1:0] c_y ;
reg                       c_en;
reg          [       7:0] c_Y0, c_Y1, c_Y2, c_Y3;
reg          [       7:0] c_U0, c_U2, c_V0, c_V2;                           // Note that c_U0, c_U2, c_V0, c_V2 is only valid when c_y is odd, because of vertical subsample.

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        c_i_frame <= 8'd0;
        c_x4 <= 0;
        c_y  <= 0;
        c_en <= 1'b0;
    end else begin
        c_i_frame <= b_i_frame;
        c_x4 <= b_x4;
        c_y  <= b_y;
        c_en <= b_en;
    end

always @ (posedge clk) begin                                                // vertical subsample
    {c_Y0, c_Y1, c_Y2, c_Y3} <= {b_Y0, b_Y1, b_Y2, b_Y3};
    c_U0 <= mean2(b_U0, b_U0_u);
    c_U2 <= mean2(b_U2, b_U2_u);
    c_V0 <= mean2(b_V0, b_V0_u);
    c_V2 <= mean2(b_V2, b_V2_u);
end





//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// stage D & E : double-buffer: buffer 2 slices
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg          [   4*8-1:0] mem_dbuf_Y [0 : ((2 * 16 * (XSIZE/4))-1)];        // Y: double-buffer memory, 16 rows, XSIZE/4 cols, each item contains 4 Y-pixels
reg          [   2*8-1:0] mem_dbuf_U [0 : ((2 *  8 * (XSIZE/4))-1)];        // U: double-buffer memory,  8 rows, XSIZE/4 cols, each item contains 2 U-pixels
reg          [   2*8-1:0] mem_dbuf_V [0 : ((2 *  8 * (XSIZE/4))-1)];        // V: double-buffer memory,  8 rows, XSIZE/4 cols, each item contains 2 V-pixels

reg                       c_flip;                                           // double-buffer write control bit
reg                       d_flop;                                           // double-buffer read control bit, when c_flip != d_flop, double-buffer is available to read

reg          [       7:0] d_i_frame;
reg          [   XB4-1:0] d_x4  ;
reg          [  YB16-1:0] d_y16 ;
reg          [       3:0] d_y_16;                                           // 0~15, to loop through all rows in the block

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        d_i_frame <= 8'd0;
        d_y16 <= 0;
        c_flip <= 1'b0;
    end else begin
        if( c_en  &&  c_x4 == max_x4  &&  c_y[3:0] == 4'd15 ) begin         // end of a inputted row of block (16 rows of Y)
            d_i_frame <= c_i_frame;
            d_y16  <= c_y[YB-1:4];
            c_flip <= ~c_flip;                                              // flip the double-buffer
        end
    end

always @ (posedge clk)                                                      // write Y double-buffer in row-first order
    if( c_en )
        mem_dbuf_Y[ {c_flip, c_y[3:0], c_x4} ] <= {c_Y0, c_Y1, c_Y2, c_Y3};

always @ (posedge clk)                                                      // write U/V double-buffer in row-first order
    if( c_en & c_y[0] ) begin                                               // only write when c_y is odd
        mem_dbuf_U[ {c_flip, c_y[3:1], c_x4} ] <= {c_U0, c_U2};
        mem_dbuf_V[ {c_flip, c_y[3:1], c_x4} ] <= {c_V0, c_V2};
    end

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        d_y_16 <= 4'd0;
        d_x4 <= 0;
        d_flop <= 1'b0;
    end else begin                                                          // update the read index to read the double-buffer in column-first order.
        if( c_flip != d_flop ) begin                                        // when c_flip != d_flop, double-buffer is available to read, the valid read data will appear at next cycle
            d_y_16 <= d_y_16 + 4'd1;
            if(d_y_16 == 4'd15) begin
                if( d_x4 < max_x4 ) begin
                    d_x4 <= d_x4 + 1;
                end else begin
                    d_x4 <= 0;
                    d_flop <= ~d_flop;                                      // end of reading a row of block (16 rows of Y), flop the double-buffer
                end
            end
        end
    end

reg          [       7:0] e_i_frame;
reg          [  XB16-1:0] e_x16;
reg          [  YB16-1:0] e_y16;
reg                       e_start_blk;
reg                       e_en_blk   ;
reg                       e_Y_en  ;
reg                       e_UV_en ;
reg          [   4*8-1:0] e_Y_rd;                                            // Y double-buffer output: 4 adjacent values
reg          [   2*8-1:0] e_U_rd;                                            // U double-buffer output: 2 adjacent values
reg          [   2*8-1:0] e_V_rd;                                            // V double-buffer output: 2 adjacent values

always @ (posedge clk) begin                                                // read double-buffer in col-first order
    e_Y_rd <= mem_dbuf_Y [ {d_flop, d_y_16     , d_x4} ];
    e_U_rd <= mem_dbuf_U [ {d_flop, d_y_16[3:1], d_x4} ];
    e_V_rd <= mem_dbuf_V [ {d_flop, d_y_16[3:1], d_x4} ];
end


always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        e_i_frame <= 8'd0;
        e_x16 <= 0;
        e_y16 <= 0;
        e_start_blk <= 0;
        e_en_blk    <= 0;
        e_Y_en      <= 0;
        e_UV_en     <= 0;
    end else begin
        e_i_frame <= d_i_frame;
        e_x16 <= (d_x4 >> 2);
        e_y16 <= d_y16;
        e_start_blk <= (c_flip != d_flop)  &&  d_x4[1:0] == 2'd0  &&  d_y_16 == 4'd0;      // start of a block (16x16 Y)
        e_en_blk    <= (c_flip != d_flop)  &&  d_x4[1:0] == 2'd3  &&  d_y_16 == 4'd15;     // end of a block (16x16 Y)
        e_Y_en      <= (c_flip != d_flop);
        e_UV_en     <= (c_flip != d_flop)  &&  d_y_16[0];
    end

// shift the double-buffer's output to get a new block
reg          [       7:0] e_Y_blk [0:15][0:15];
reg          [       7:0] e_U_blk [0:7 ][0:7 ];
reg          [       7:0] e_V_blk [0:7 ][0:7 ];

always @ (*) begin
    {e_Y_blk[15][12], e_Y_blk[15][13], e_Y_blk[15][14], e_Y_blk[15][15]} = e_Y_rd;
    {e_U_blk[7][6], e_U_blk[7][7]} = e_U_rd;
    {e_V_blk[7][6], e_V_blk[7][7]} = e_V_rd;
end

integer x, y, yt, i, j, k;

always @ (posedge clk) begin
    if( e_Y_en ) begin                                    // shift to save a block of Y (16x16 Y)
        for    (x=0; x<16; x=x+1)
            for(y=0; y<15; y=y+1)
                e_Y_blk[y][x] <= e_Y_blk[y+1][x];
        for(x=0; x<12; x=x+1)
            e_Y_blk[15][x] <= e_Y_blk[0][x+4];
    end
    if( e_UV_en ) begin                                   // shift to save a block of U/V (8x8 U and 8x8 V)
        for    (x=0; x<8; x=x+1)
            for(y=0; y<7; y=y+1) begin
                e_U_blk[y][x] <= e_U_blk[y+1][x];
                e_V_blk[y][x] <= e_V_blk[y+1][x];
            end
        for(x=0; x<6; x=x+1) begin
            e_U_blk[7][x] <= e_U_blk[0][x+2];
            e_V_blk[7][x] <= e_V_blk[0][x+2];
        end
    end
end





//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// stage X & Y & Z : read reference frame memory
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg          [   8*8-1:0] mem_ref_Y  [ 0 : (( (YSIZE  ) * (XSIZE/8 )     ) -1) ];   //   Y reference frame memory : (YSIZE  ) rows, XSIZE/8  cols                  , each item contains  8 Y pixels
reg          [   8*8-1:0] mem_ref_UV [ 0 : (( (YSIZE/2) * (XSIZE/16) * 2 ) -1) ];   // U/V reference frame memory : (YSIZE/2) rows, XSIZE/16 cols, 2 channels (U/V), each item contains  8 U or V pixels

reg          [       4:0] x_cnt;
reg          [  XB16-1:0] x_x16;
reg          [  YB16-1:0] x_y16;                                       // temporary variable, not real register
reg                       x_x8_2;
reg          [    YB-1:0] x_y;

reg                       y_Y_en;
reg                       y_U_en;
reg                       y_V_en;

reg          [   8*8-1:0] y_Y_rd;
reg          [   8*8-1:0] y_UV_rd;

reg                       z_Y_en;
reg                       z_U_en;
reg                       z_V_en;

reg          [   8*8-1:0] z_Y_rd;
reg          [   8*8-1:0] z_UV_rd;

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        y_Y_en <= 1'b0;
        y_U_en <= 1'b0;
        y_V_en <= 1'b0;
        x_x16  <= 0;
        x_y    <= 0;
        x_x8_2 <= 1'b0;
        x_cnt  <= 5'h1F;
    end else begin                                                         // reference frame read control :
        y_Y_en <= 1'b0; 
        y_U_en <= 1'b0;
        y_V_en <= 1'b0;
        if(e_start_blk) begin                                              // when start to read a current block, start to read the reference blocks (whose position is at the right side of the current block)
            if          ( e_y16 == max_y16  &&  e_x16 == max_x16 ) begin   //   current block is at the bottom-right corner of the current image
                x_x16 <= 0;                                                //     the reference block to read is at the top-left corner of reference image
                x_y16  = 0;
            end else if ( e_x16 == max_x16 ) begin                         //   current block is the right-most block of the current image
                x_x16 <= 0;                                                //     the reference block to read is the left-most block in the next row
                x_y16  = e_y16 + 1;
            end else begin                                                 //   current block is NOT the right-most block of the current image
                x_x16 <= e_x16 + 1;                                        //     the reference block to read is at the right side of the current block
                x_y16  = e_y16;
            end
            x_y    <= (x_y16 << 4) - YR;
            x_x8_2 <= 1'b0;
            x_cnt  <= 5'd0;
        end else if( x_cnt < (16+2*YR) ) begin                             // for each block, need to read YR+16+YR lines of Y
            if(x_x8_2) begin
                x_cnt <= x_cnt + 5'd1;
                x_y   <= x_y + 1;
            end
            x_x8_2 <= ~x_x8_2;
            y_Y_en <= 1'b1;
            y_U_en <= ~x_y[0] & ~x_x8_2;
            y_V_en <= ~x_y[0] &  x_x8_2;
        end
    end

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        z_Y_en <= 1'b0;
        z_U_en <= 1'b0;
        z_V_en <= 1'b0;
    end else begin
        z_Y_en <= y_Y_en;
        z_U_en <= y_U_en;
        z_V_en <= y_V_en;
    end

always @ (posedge clk) begin
    y_Y_rd  <= mem_ref_Y [ {x_y        , x_x16, x_x8_2} ] ;
    y_UV_rd <= mem_ref_UV[ {x_y[YB-1:1], x_x16, x_x8_2} ] ;
end

always @ (posedge clk) begin
    z_Y_rd  <= y_Y_rd;
    z_UV_rd <= y_UV_rd;
end

reg [7:0] z_Y_ref [-YR:16+YR-1] [0:15];
reg [7:0] z_U_ref [-UR: 8+UR-1] [0:7 ];
reg [7:0] z_V_ref [-UR: 8+UR-1] [0:7 ];

always @ (posedge clk) begin
    if(z_Y_en) begin
        for     (x=0; x<8; x=x+1) begin
            for (y=-YR; y<16+YR; y=y+1)
                z_Y_ref[y][x] <= z_Y_ref[y][x+8];
            for (y=-YR; y<16+YR-1; y=y+1)
                z_Y_ref[y][x+8] <= z_Y_ref[y+1][x];
            z_Y_ref[16+YR-1][x+8] <= z_Y_rd[x*8+:8];     // push the new data to the last item of z_Y_ref
        end
    end
    if(z_U_en) begin
        for     (x=0; x<8; x=x+1) begin
            for (y=-UR; y<8+UR-1; y=y+1)
                z_U_ref[y][x] <= z_U_ref[y+1][x];        // shift z_U_ref
            z_U_ref[8+UR-1][x] <= z_UV_rd[x*8+:8];       // push the new data to the last item of z_U_ref
        end
    end
    if(z_V_en) begin
        for     (x=0; x<8; x=x+1) begin
            for (y=-UR; y<8+UR-1; y=y+1)
                z_V_ref[y][x] <= z_V_ref[y+1][x];        // shift z_V_ref
            z_V_ref[8+UR-1][x] <= z_UV_rd[x*8+:8];       // push the new data to the last item of z_V_ref
        end
    end
end





//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// stage F : motion estimation
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg          [       7:0] f_i_frame;
reg          [  XB16-1:0] f_x16 ;
reg          [  YB16-1:0] f_y16 ;

reg          [      15:0] f_Y_sum ;
reg          [       7:0] f_Y_mean;

reg          [       7:0] f_Y_blk [0:15][0:15];                            // Y current block
reg          [       7:0] f_U_blk [0:7][0:7];                              // U current block
reg          [       7:0] f_V_blk [0:7][0:7];                              // V current block

reg          [       7:0] f_Y_ref [-YR:16+YR-1][-YR:16+16-1];              // Y reference
reg          [       7:0] f_U_ref [-UR: 8+UR-1][-UR:8+8-1];                // U reference
reg          [       7:0] f_V_ref [-UR: 8+UR-1][-UR:8+8-1];                // V reference

reg          [       7:0] f_Y_prd [0:15][0:15];                            // Y predicted block
reg          [       7:0] f_U_prd [-UR:8+UR-1][-UR:8+UR-1];                // U predicted block
reg          [       7:0] f_V_prd [-UR:8+UR-1][-UR:8+UR-1];                // V predicted block

reg          [       7:0] f_Y_tmp [-YR:16+YR-1][-YR:16+YR-1];              // Y temporary reference map for full pixel search
reg          [       7:0] f_Y_hlf [-1:31][-1:31];                          // Y temporary reference map for half pixel search

reg          [      11:0] f_diff  [-YR:YR][-YR:YR];                        // up: YR,  middle: 1,  down: YR.    left: YR,  middle: 1,  right: YR.    
reg                       f_over  [-YR:YR][-YR:YR];                        // 

reg   signed [       1:0] f_mvxh , f_mvyh;                       // -1, 0, +1
reg   signed [       4:0] f_mvx  , f_mvy;                        //
reg                       f_inter ;

reg                       f_en_blk ;

reg          [       3:0] f_cnt ;                                      // 0~15

localparam  [        3:0] MV_IDLE              = 4'd0 ,
                          PREPARE_SEARCH_FULL  = 4'd1 ,
                          CALC_DIFF            = 4'd2 ,
                          CALC_MIN             = 4'd3 ,
                          CALC_MOTION_VECTOR_Y = 4'd4 ,
                          CALC_MOTION_VECTOR_X = 4'd5 ,
                          REF_SHIFT_Y          = 4'd6 ,
                          REF_SHIFT_X          = 4'd7 ,
                          PREPARE_SEARCH_HALF  = 4'd8 ,
                          CALC_DIFF_HALF       = 4'd9 ,
                          CALC_MIN_HALF1       = 4'd10,
                          CALC_MIN_HALF2       = 4'd11,
                          REF_UV_SHIFT_Y       = 4'd12,
                          REF_UV_SHIFT_X       = 4'd13,
                          PREDICT              = 4'd14;

reg          [       3:0] f_stat = MV_IDLE;

//enum reg     [       3:0]  {
//    MV_IDLE , PREPARE_SEARCH_FULL, CALC_DIFF , CALC_MIN ,
//    CALC_MOTION_VECTOR_Y , CALC_MOTION_VECTOR_X ,
//    REF_SHIFT_Y , REF_SHIFT_X ,
//    PREPARE_SEARCH_HALF , CALC_DIFF_HALF ,
//    CALC_MIN_HALF1 , CALC_MIN_HALF2 ,
//    REF_UV_SHIFT_Y , REF_UV_SHIFT_X , PREDICT
//} f_stat ;

reg          [      11:0] diff ;                        // temporary variable, not real register
reg                       tmpbit1, tmpbit2 ;            // temporary variable, not real register


always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        f_en_blk <= 1'b0;
        f_cnt <= 4'd0;
        f_stat <= MV_IDLE;
    end else begin
        f_en_blk <= 1'b0;
        f_cnt <= 4'd0;
        
        case (f_stat)
            MV_IDLE : begin
                if(e_en_blk)
                    f_stat <= PREPARE_SEARCH_FULL;
            end
            
            PREPARE_SEARCH_FULL :
                f_stat <= CALC_DIFF;
            
            CALC_DIFF : begin
                if(f_cnt < 4'd15)
                    f_cnt  <= f_cnt + 4'd1;
                else
                    f_stat <= CALC_MIN;
            end
            
            CALC_MIN : begin
                if( f_cnt < 4'd5 )
                    f_cnt  <= f_cnt + 4'd1;
                else
                    f_stat <= CALC_MOTION_VECTOR_Y;
            end
            
            CALC_MOTION_VECTOR_Y :
                f_stat <= CALC_MOTION_VECTOR_X;
            
            CALC_MOTION_VECTOR_X :
                f_stat <= REF_SHIFT_Y;
            
            REF_SHIFT_Y : begin
                if(f_cnt < (YR-1) )
                    f_cnt  <= f_cnt + 4'd1;
                else
                    f_stat <= REF_SHIFT_X;
            end
            
            REF_SHIFT_X : begin
                if(f_cnt < (YR-1) )
                    f_cnt  <= f_cnt + 4'd1;
                else
                    f_stat <= PREPARE_SEARCH_HALF;
            end
            
            PREPARE_SEARCH_HALF :
                f_stat <= CALC_DIFF_HALF;
            
            CALC_DIFF_HALF : begin
                if(f_cnt < 4'd15)
                    f_cnt  <= f_cnt + 4'd1;
                else
                    f_stat <= CALC_MIN_HALF1;
            end
            
            CALC_MIN_HALF1 :
                f_stat <= CALC_MIN_HALF2;
            
            CALC_MIN_HALF2 :
                f_stat <= REF_UV_SHIFT_Y;
            
            REF_UV_SHIFT_Y : begin
                if(f_cnt < 4'd2)
                    f_cnt  <= f_cnt + 4'd1;
                else
                    f_stat <= REF_UV_SHIFT_X;
            end
            
            REF_UV_SHIFT_X : begin
                if(f_cnt < 4'd2)
                    f_cnt  <= f_cnt + 4'd1;
                else
                    f_stat <= PREDICT;
            end
            
            default: begin //PREDICT : begin
                f_stat <= MV_IDLE;
                f_en_blk <= 1'b1;
            end
        endcase
    end


always @ (posedge clk)
    case(f_stat)
        
        // state: start, load current block and its reference --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        MV_IDLE : begin
            if(e_en_blk) begin
                f_i_frame <= e_i_frame;
                f_y16 <= e_y16;
                f_x16 <= e_x16;
            end
            
            f_Y_sum <= 16'd0;
                
            for     (y=0; y<16; y=y+1)
                for (x=0; x<16; x=x+1)
                    f_Y_blk[y][x] <= e_Y_blk[y][x];            // load current Y block
                
            for     (y=0; y<8; y=y+1)
                for (x=0; x<8; x=x+1) begin
                    f_U_blk[y][x] <= e_U_blk[y][x];            // load current U block
                    f_V_blk[y][x] <= e_V_blk[y][x];            // load current V block
                end
            
            if(e_en_blk) begin
                for     (y=-YR; y<16+YR; y=y+1) begin
                    for (x=-YR; x<16; x=x+1)
                        f_Y_ref[y][x] <= f_Y_ref[y][x+16];         // left shift old Y reference 16 steps
                    for (x=0; x<16; x=x+1)
                        f_Y_ref[y][x+16] <= z_Y_ref[y][x];         // load new Y reference
                end
                    
                for     (y=-UR; y<8+UR; y=y+1) begin
                    for (x=-UR; x<8   ; x=x+1) begin
                        f_U_ref[y][x] <= f_U_ref[y][x+8];          // left shift old U reference by 8 steps
                        f_V_ref[y][x] <= f_V_ref[y][x+8];          // left shift old V reference by 8 steps
                    end
                    for (x=0; x<8; x=x+1) begin
                        f_U_ref[y][x+8] <= z_U_ref[y][x];          // load new U reference
                        f_V_ref[y][x+8] <= z_V_ref[y][x];          // load new V reference
                    end
                end
            end
        end
        
        // state: YR cycles --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        PREPARE_SEARCH_FULL : begin
            for     (y=-YR; y<16+YR; y=y+1)
                for (x=-YR; x<16+YR; x=x+1)
                    f_Y_tmp[y][x] <= f_Y_ref[y][x];                  // load f_Y_tmp from f_Y_ref : prepare for REF_SHIFT_Y
            
            for     (y=-YR; y<=YR; y=y+1)
                for (x=-YR; x<=YR; x=x+1) begin
                    f_diff[y][x] <= 12'd0;                           // clear diff map
                    f_over[y][x] <=( (f_x16 == 0       && x<0 ) ||   // for left-most   block, disable the motion-vector that mvx<0,
                                     (f_x16 == max_x16 && x>0 ) ||   // for right-most  block, disable the motion-vector that mvx>0,
                                     (f_y16 == 0       && y<0 ) ||   // for top-most    block, disable the motion-vector that mvy<0,
                                     (f_y16 == max_y16 && y>0 ) );   // for bottom-most block, disable the motion-vector that mvy>0.
                end
        end
        
        // state: 16 cycles --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        CALC_DIFF : begin
            for     (y=0; y<16; y=y+1)
                for (x=0; x<16; x=x+1)
                    f_Y_blk[y][x] <= f_Y_blk[y][(x+1)%16];             // cyclic left shift f_Y_blk by 1 step
            
            for     (y=-YR; y<16+YR  ; y=y+1)
                for (x=-YR; x<16+YR-1; x=x+1)
                    f_Y_tmp[y][x] <= f_Y_tmp[y][x+1];                  // left shift f_Y_tmp by 1 step
            
            diff = 12'd0;
            for(y=0; y<16; y=y+1)
                diff = diff + { 4'h0 , f_Y_blk[y][0] };
            f_Y_sum <= f_Y_sum + {4'h0, diff};                         // calculate sum of f_Y_blk
            
            for     (y=-YR; y<=YR; y=y+1)
                for (x=-YR; x<=YR; x=x+1) begin
                    diff = 12'd0;
                    for (yt=0; yt<16; yt=yt+1)
                        diff = diff + { 4'h0 , func_diff( f_Y_blk[yt][0] , f_Y_tmp[yt+y][x] ) };
                    if( ~f_over[y][x] )
                        {f_over[y][x], f_diff[y][x]} <= {1'b0, f_diff[y][x]} + {1'b0, diff} ;
                end
        end
        
        // state: 6 cycles --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        CALC_MIN : begin
            tmpbit1 = 1'b1;
            for     (y=-YR; y<=YR; y=y+1)
                for (x=-YR; x<=YR; x=x+1)
                    tmpbit1 = tmpbit1 & (f_over[y][x] | f_diff[y][x][11]) ;
            
            tmpbit2 = 1'b1;
            for     (y=-YR; y<=YR; y=y+1)
                for (x=-YR; x<=YR; x=x+1)
                    tmpbit2 = tmpbit2 & (f_over[y][x] | (f_diff[y][x][11] & ~tmpbit1) | f_diff[y][x][10]) ;
            
            for     (y=-YR; y<=YR; y=y+1)
                for (x=-YR; x<=YR; x=x+1) begin
                    f_over[y][x] <= f_over[y][x] | (f_diff[y][x][11] & ~tmpbit1) | (f_diff[y][x][10] & ~tmpbit2);
                    f_diff[y][x] <= f_diff[y][x] << 2 ;
                end
        end
        
        // state: 1 cycle --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        CALC_MOTION_VECTOR_Y : begin
            f_mvy <= 5'd0;
            for     (y=-YR; y<=YR; y=y+1) begin
                tmpbit1 = 1'b1;
                for (x=-YR; x<=YR; x=x+1)
                    tmpbit1 = tmpbit1 & f_over[y][x] ;
                if( ~tmpbit1 )
                    f_mvy <= y[4:0];                    // use f_over to get the y of motion vector's x
            end
        end
        
        // state: 1 cycle --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        CALC_MOTION_VECTOR_X : begin
            f_mvx <= 5'd0;
            for (x=-YR; x<=YR; x=x+1)
                if( ~f_over[f_mvy][x] )
                    f_mvx <= x[4:0];                    // use f_over to get the x of motion vector's x
            
            for     (y=-YR; y<16+YR; y=y+1)
                for (x=-YR; x<16+YR; x=x+1)
                    f_Y_tmp[y][x] <= f_Y_ref[y][x];     // load f_Y_tmp from f_Y_ref : prepare for REF_SHIFT_Y
        end
        
        
        // state: YR cycles --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        REF_SHIFT_Y : begin
            if      ( f_mvy > 5'sd0  &&  {1'b0, f_cnt} < $unsigned( f_mvy) )  // up shift Y
                for     (y=0  ; y<16+YR; y=y+1)                               // needn't to shift the pixels of y<-1, since they are discarded
                    for (x=-YR; x<16+YR; x=x+1)
                        f_Y_tmp[y-1][x] <= f_Y_tmp[y][x] ;
            else if ( f_mvy < 5'sd0  &&  {1'b0, f_cnt} < $unsigned(-f_mvy) )  // down shift Y
                for     (y=-YR; y<16   ; y=y+1)                               // needn't to shift the pixels of y>16, since they are discarded
                    for (x=-YR; x<16+YR; x=x+1)
                        f_Y_tmp[y+1][x] <= f_Y_tmp[y][x] ;
        end
        
        // state: YR cycles --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        REF_SHIFT_X : begin
            if      ( f_mvx > 5'sd0  &&  {1'b0, f_cnt} < $unsigned( f_mvx) )  // left shift Y
                for     (y=-1; y<=16  ; y=y+1)                                // needn't to shift the pixels of y<-1 and y>16, since they are discarded
                    for (x=0 ; x<16+YR; x=x+1)                                // needn't to shift the pixels of x<-1, since they are discarded
                        f_Y_tmp[y][x-1] <= f_Y_tmp[y][x] ;
            else if ( f_mvx < 5'sd0  &&  {1'b0, f_cnt} < $unsigned(-f_mvx) )  // right shift Y
                for     (y=-1; y<=16; y=y+1)                                  // needn't to shift the pixels of y<-1 and y>16, since they are discarded
                    for (x=-YR; x<16; x=x+1)                                  // needn't to shift the pixels of x>16, since they are discarded
                        f_Y_tmp[y][x+1] <= f_Y_tmp[y][x] ;
        end
        
        // state: 1 cycle --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        PREPARE_SEARCH_HALF : begin
            f_Y_mean <= f_Y_sum[15:8];
            
            for    (y=-1; y<16; y=y+1)
                for(x=-1; x<16; x=x+1) begin
                    if(-2<y*2   && -2<x*2  ) f_Y_hlf[y*2  ][x*2  ] <=        f_Y_tmp[y][x];
                    if(-2<y*2   && -2<x*2+1) f_Y_hlf[y*2  ][x*2+1] <= mean2( f_Y_tmp[y][x], f_Y_tmp[y][x+1] );
                    if(-2<y*2+1 && -2<x*2  ) f_Y_hlf[y*2+1][x*2  ] <= mean2( f_Y_tmp[y][x], f_Y_tmp[y+1][x] );
                    if(-2<y*2+1 && -2<x*2+1) f_Y_hlf[y*2+1][x*2+1] <= mean4( f_Y_tmp[y][x], f_Y_tmp[y][x+1], f_Y_tmp[y+1][x], f_Y_tmp[y+1][x+1] );
                end
            
            for     (y=-1; y<=1; y=y+1)
                for (x=-1; x<=1; x=x+1) begin
                    f_diff[y][x] <= 12'd0;
                    f_over[y][x] <=( ( (f_x16 == 0       || f_mvx == $signed(-YR) ) && x<0 ) ||
                                     ( (f_x16 == max_x16 || f_mvx == $signed( YR) ) && x>0 ) ||
                                     ( (f_y16 == 0       || f_mvy == $signed(-YR) ) && y<0 ) ||
                                     ( (f_y16 == max_y16 || f_mvy == $signed( YR) ) && y>0 ) );
                end
        end
        
        // state: 16 cycles --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        CALC_DIFF_HALF : begin
            for    (y=0; y<16; y=y+1)
                for(x=0; x<16; x=x+1)
                    f_Y_blk[y][x] <= f_Y_blk[y][(x+1)%16];               // cyclic left shift f_Y_blk by 1 step
            
            for    (y=-1; y<32; y=y+1)
                for(x=-1; x<30; x=x+1)
                    f_Y_hlf[y][x] <= f_Y_hlf[y][x+2];                    // left shift f_Y_hlf by 2 steps
            
            diff = 12'd0;
            for(y=0; y<16; y=y+1)
                diff = diff + { 4'h0 , func_diff( f_Y_blk[y][0] , f_Y_mean ) };
            f_Y_sum <= f_Y_sum + { 4'h0 , diff };                            // calculate diff of f_Y_blk and f_Y_mean
            
            for     (y=-1; y<=1; y=y+1)
                for (x=-1; x<=1; x=x+1) begin
                    diff = 12'd0;
                    for (yt=0; yt<16; yt=yt+1)
                        diff = diff + { 4'h0 , func_diff( f_Y_blk[yt][0] , f_Y_hlf[y+2*yt][x] ) };
                    if( ~f_over[y][x] )
                        {f_over[y][x], f_diff[y][x]} <= {1'b0, f_diff[y][x]} + {1'b0, diff} ;
                end
        end
        
        // state: 1 cycle --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        CALC_MIN_HALF1 : begin
            diff = (f_Y_sum[15:12] == 4'd0) ? f_Y_sum[11:0] : 12'hfff;
            
            // find min value in f_diff (a faster way)
            case( find_min_in_10_values(
                    { f_over[-1][-1], f_diff[-1][-1] },
                    { f_over[-1][ 0], f_diff[-1][ 0] },
                    { f_over[-1][ 1], f_diff[-1][ 1] },
                    { f_over[ 0][-1], f_diff[ 0][-1] },
                    { f_over[ 0][ 0], f_diff[ 0][ 0] },
                    { f_over[ 0][ 1], f_diff[ 0][ 1] },
                    { f_over[ 1][-1], f_diff[ 1][-1] },
                    { f_over[ 1][ 0], f_diff[ 1][ 0] },
                    { f_over[ 1][ 1], f_diff[ 1][ 1] },
                    {           1'b0, diff           }  ) )
                4'd0    : begin  f_mvyh <= -2'sd1;  f_mvxh <= -2'sd1;  f_inter <= 1'b1;  end
                4'd1    : begin  f_mvyh <= -2'sd1;  f_mvxh <=  2'sd0;  f_inter <= 1'b1;  end
                4'd2    : begin  f_mvyh <= -2'sd1;  f_mvxh <=  2'sd1;  f_inter <= 1'b1;  end
                4'd3    : begin  f_mvyh <=  2'sd0;  f_mvxh <= -2'sd1;  f_inter <= 1'b1;  end
                4'd4    : begin  f_mvyh <=  2'sd0;  f_mvxh <=  2'sd0;  f_inter <= 1'b1;  end
                4'd5    : begin  f_mvyh <=  2'sd0;  f_mvxh <=  2'sd1;  f_inter <= 1'b1;  end
                4'd6    : begin  f_mvyh <=  2'sd1;  f_mvxh <= -2'sd1;  f_inter <= 1'b1;  end
                4'd7    : begin  f_mvyh <=  2'sd1;  f_mvxh <=  2'sd0;  f_inter <= 1'b1;  end
                4'd8    : begin  f_mvyh <=  2'sd1;  f_mvxh <=  2'sd1;  f_inter <= 1'b1;  end
                default : begin  f_mvyh <=  2'sd0;  f_mvxh <=  2'sd0;  f_inter <= 1'b0;  end
            endcase
        end
        
        // state: 1 cycle --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        CALC_MIN_HALF2 : begin
            if( f_i_frame == 8'd0 ) begin                                         // I-frame
                f_inter <= 1'b0;
                f_mvyh <= 2'd0;
                f_mvxh <= 2'd0;
                f_mvy  <= 5'd0;
                f_mvx  <= 5'd0;
            end else begin                                                      // P-frame
                f_mvy  <= (f_mvy << 1) + f_mvyh;
                f_mvx  <= (f_mvx << 1) + f_mvxh;
            end
            
            for    (y=-1; y<16; y=y+1)
                for(x=-1; x<16; x=x+1) begin
                    if(-2<y*2   && -2<x*2  ) f_Y_hlf[y*2  ][x*2  ] <=        f_Y_tmp[y][x];
                    if(-2<y*2   && -2<x*2+1) f_Y_hlf[y*2  ][x*2+1] <= mean2( f_Y_tmp[y][x], f_Y_tmp[y][x+1] );
                    if(-2<y*2+1 && -2<x*2  ) f_Y_hlf[y*2+1][x*2  ] <= mean2( f_Y_tmp[y][x], f_Y_tmp[y+1][x] );
                    if(-2<y*2+1 && -2<x*2+1) f_Y_hlf[y*2+1][x*2+1] <= mean4( f_Y_tmp[y][x], f_Y_tmp[y][x+1], f_Y_tmp[y+1][x], f_Y_tmp[y+1][x+1] );
                end
            
            for     (y=-UR; y<8+UR; y=y+1)
                for (x=-UR; x<8+UR; x=x+1) begin
                    f_U_prd[y][x] <= f_U_ref[y][x] ;
                    f_V_prd[y][x] <= f_V_ref[y][x] ;
                end
        end
        
        // state: 3 cycle --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        REF_UV_SHIFT_Y : begin
            if( f_cnt == 4'd0 && f_mvyh >= 2'sd0  ||  f_cnt == 4'd1 && f_mvyh >= 2'sd1 ) begin    // up shift Y-half (f_Y_hlf)
                for    (y=-1; y<31; y=y+1)
                    for(x=-1; x<32; x=x+1)
                        f_Y_hlf[y][x] <= f_Y_hlf[y+1][x]; 
            end
            
            if      ( f_mvy > 5'sd0  &&  {1'b0, f_cnt} < $unsigned(  f_mvy>>>2 ) ) // up shift U/V
                for     (y=1  ; y<8+UR; y=y+1)                                     // needn't to shift the pixels of y<0, since they are discarded
                    for (x=-UR; x<8+UR; x=x+1) begin
                        f_U_prd[y-1][x] <= f_U_prd[y][x] ;
                        f_V_prd[y-1][x] <= f_V_prd[y][x] ;
                    end
            else if ( f_mvy < 5'sd0  &&  {1'b0, f_cnt} < $unsigned(-(f_mvy>>>2)) ) // down shift V/V
                for     (y=-UR; y<8   ; y=y+1)                                     // needn't to shift the pixels of y>8 , since they are discarded
                    for (x=-UR; x<8+UR; x=x+1) begin
                        f_U_prd[y+1][x] <= f_U_prd[y][x] ;
                        f_V_prd[y+1][x] <= f_V_prd[y][x] ;
                    end
        end
        
        // state: 3 cycle --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        REF_UV_SHIFT_X : begin
            if( f_cnt == 4'd0 && f_mvxh >= 2'sd0  ||  f_cnt == 4'd1 && f_mvxh >= 2'sd1 ) begin    // left shift Y-half (f_Y_hlf)
                for    (y=-1; y<30; y=y+1)                                         // needn't to shift y>=30, since they are discarded
                    for(x=-1; x<31; x=x+1)
                        f_Y_hlf[y][x] <= f_Y_hlf[y][x+1];
            end
            
            if      ( f_mvx > 5'sd0  &&  {1'b0, f_cnt} < $unsigned(  f_mvx>>>2 ) ) // left shift U/V
                for     (y=0; y<=8  ; y=y+1)                                       // needn't to shift the pixels of y<0 and y>8, since they are discarded
                    for (x=1; x<8+UR; x=x+1) begin                                 // needn't to shift the pixels of x<0, since they are discarded
                        f_U_prd[y][x-1] <= f_U_prd[y][x] ;
                        f_V_prd[y][x-1] <= f_V_prd[y][x] ;
                    end
            else if ( f_mvx < 5'sd0  &&  {1'b0, f_cnt} < $unsigned(-(f_mvx>>>2)) ) // right shift U/V
                for     (y=0; y<=8 ; y=y+1)                                        // needn't to shift the pixels of y<0 and y>8, since they are discarded
                    for (x=-UR; x<8; x=x+1) begin                                  // needn't to shift the pixels of x>8, since they are discarded
                        f_U_prd[y][x+1] <= f_U_prd[y][x] ;
                        f_V_prd[y][x+1] <= f_V_prd[y][x] ;
                    end
        end
        
        // state: 1 cycle --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
        PREDICT : begin
            for     (y=0; y<16; y=y+1)
                for (x=0; x<16; x=x+1)
                    if ( ~f_inter )
                        f_Y_prd[y][x] <= 8'h80;
                    else
                        f_Y_prd[y][x] <= f_Y_hlf[2*y-1][2*x-1];
                    
            for     (y=0; y<8; y=y+1)
                for (x=0; x<8; x=x+1)
                    if( ~f_inter ) begin
                        f_U_prd[y][x] <= 8'h80;
                        f_V_prd[y][x] <= 8'h80;
                    end else if ( ((f_mvy>>>1) & 1)  &  ((f_mvx>>>1) & 1) ) begin
                        f_U_prd[y][x] <= mean4( f_U_prd[y][x], f_U_prd[y][x+1], f_U_prd[y+1][x], f_U_prd[y+1][x+1] ) ;
                        f_V_prd[y][x] <= mean4( f_V_prd[y][x], f_V_prd[y][x+1], f_V_prd[y+1][x], f_V_prd[y+1][x+1] ) ;
                    end else if ( (f_mvx>>>1) & 1 ) begin
                        f_U_prd[y][x] <= mean2( f_U_prd[y][x], f_U_prd[y][x+1] ) ;
                        f_V_prd[y][x] <= mean2( f_V_prd[y][x], f_V_prd[y][x+1] ) ;
                    end else if ( (f_mvy>>>1) & 1 ) begin
                        f_U_prd[y][x] <= mean2( f_U_prd[y][x], f_U_prd[y+1][x] ) ;
                        f_V_prd[y][x] <= mean2( f_V_prd[y][x], f_V_prd[y+1][x] ) ;
                    end else begin
                        f_U_prd[y][x] <= f_U_prd[y][x];
                        f_V_prd[y][x] <= f_V_prd[y][x];
                    end
        end
    endcase





//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// stage G : DCT, including phase 1 (right multiply DCTM_transposed) and phase 2 (left multiply DCTM), then quantize.
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg          [       5:0] g_cnt;

reg          [       7:0] g_i_frame;
reg          [  XB16-1:0] g_x16;
reg          [  YB16-1:0] g_y16;
reg                       g_inter;
reg   signed [       4:0] g_mvx , g_mvy ;

reg          [       7:0] g_tiles_prd [0:47][0:7];        // predicted tiles of current block : Y00, Y01, Y10, Y11, U, V
reg   signed [       8:0] g_tiles     [0:47][0:7];        // residual  tiles of current block : Y00, Y01, Y10, Y11, U, V

reg   signed [ 18+DCTP:0] g_dct_res1  [0:7][0:7];         // 21 bits = 9+10+3-1
reg   signed [ 18+DCTP:0] g_dct_res2  [0:7][0:7];         // 21 bits
reg   signed [      16:0] g_dct_res3  [0:7][0:7];         // 17 bits = 21+10+3-1-16
reg   signed [      11:0] g_quant     [0:7][0:7];         // 12 bits

reg                       g_en_tile  ;
reg          [       2:0] g_num_tile ;

reg   signed [ 18+DCTP:0] g_t1;                           // temporary variable not real register
reg   signed [28+2*DCTP:0] g_t2;                          // temporary variable not real register
reg          [      15:0] g_t3;                           // temporary variable not real register


always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        g_cnt <= 6'd0;
        g_en_tile  <= 1'b0;
        g_num_tile <= 3'd0;
    end else begin
        if( f_en_blk )
            g_cnt <= 6'd1;
        else if (g_cnt != 6'd0)
            g_cnt <= g_cnt + 6'd1;
        
        g_en_tile  <= 1'b0;
        if( g_cnt == 6'd18 || g_cnt == 6'd26 || g_cnt == 6'd34 || g_cnt == 6'd42 || g_cnt == 6'd50 || g_cnt == 6'd58 ) begin
            g_en_tile  <= 1'b1;
            g_num_tile <= g_cnt[5:3] - 3'd2;       // 0->Y00   1->Y01   2->Y10   3->Y11   4->U   5->V
        end
    end


always @ (posedge clk)
    if( f_en_blk ) begin
        g_i_frame <= f_i_frame;
        g_y16 <= f_y16;
        g_x16 <= f_x16;
        g_inter <= f_inter;
        g_mvx <= f_mvx;
        g_mvy <= f_mvy;
        
        for     (y=0; y<8 ; y=y+1)
            for (x=0; x<8 ; x=x+1) begin
                g_tiles_prd[y   ][x  ] <= f_Y_prd[y][x];
                g_tiles    [y   ][x  ] <= $signed( {2'h0, f_Y_blk[y][x]} ) - $signed( {2'h0, f_Y_prd[y][x]} );
            end
        
        for     (y=0; y<8 ; y=y+1)
            for (x=8; x<16; x=x+1) begin
                g_tiles_prd[y+8 ][x-8] <= f_Y_prd[y][x];
                g_tiles    [y+8 ][x-8] <= $signed( {2'h0, f_Y_blk[y][x]} ) - $signed( {2'h0, f_Y_prd[y][x]} );
            end
        
        for     (y=8; y<16; y=y+1)
            for (x=0; x<8 ; x=x+1) begin
                g_tiles_prd[y+8 ][x  ] <= f_Y_prd[y][x];
                g_tiles    [y+8 ][x  ] <= $signed( {2'h0, f_Y_blk[y][x]} ) - $signed( {2'h0, f_Y_prd[y][x]} );
            end
        
        for     (y=8; y<16; y=y+1)
            for (x=8; x<16; x=x+1) begin
                g_tiles_prd[y+16][x-8] <= f_Y_prd[y][x];
                g_tiles    [y+16][x-8] <= $signed( {2'h0, f_Y_blk[y][x]} ) - $signed( {2'h0, f_Y_prd[y][x]} );
            end
        
        for     (y=0; y<8; y=y+1)
            for (x=0; x<8; x=x+1) begin
                g_tiles_prd[y+32][x  ] <= f_U_prd[y][x];
                g_tiles    [y+32][x  ] <= $signed( {2'h0, f_U_blk[y][x]} ) - $signed( {2'h0, f_U_prd[y][x]} );
            end
        
        for     (y=0; y<8; y=y+1)
            for (x=0; x<8; x=x+1) begin
                g_tiles_prd[y+40][x  ] <= f_V_prd[y][x];
                g_tiles    [y+40][x  ] <= $signed( {2'h0, f_V_blk[y][x]} ) - $signed( {2'h0, f_V_prd[y][x]} );
            end
            
    end else begin
        for     (x=0; x<8 ; x=x+1) begin
            for (y=0; y<47; y=y+1)
                g_tiles[y][x] <= g_tiles[y+1][x];              // up shift g_tiles
            g_tiles[47][x] <= 9'sd0;
        end
    end


always @ (posedge clk) begin
    // DCT phase 1 : right multiply DCTM_transposed
    // calculate when      g_cnt = 1~8, 9~16, 17~24, 25~32, 33~40, 41~48
    // produce result when g_cnt =   9,   17,    25,    33,    41,    49
    for (j=0; j<8; j=j+1) begin
        g_t1 = 0;
        for (k=0; k<8; k=k+1) 
            g_t1 = g_t1 + (g_tiles[0][k] * DCTM[j][k]);        // Note that DCTM [j][k] == DCTM_transposed [k][j]
        g_dct_res1[7][j] <= g_t1;                              // push the DCT phase 1 result to the last row of g_dct_res1
        for (i=0; i<7; i=i+1)
            g_dct_res1[i][j] <= g_dct_res1[i+1][j];            // up shift g_dct_res1
    end
    
    // save the 8x8 result of DCT phase 1
    if( g_cnt == 6'd9 || g_cnt == 6'd17 || g_cnt == 6'd25 || g_cnt == 6'd33 || g_cnt == 6'd41 || g_cnt == 6'd49 ) begin
        for (i=0; i<8; i=i+1)
            for (j=0; j<8; j=j+1)
                g_dct_res2[i][j] <= g_dct_res1[i][j] ;         // save the 8x8 result of DCT phase 1 to g_dct_res2
    end else begin
        for (i=0; i<8; i=i+1) begin
            for (j=0; j<7; j=j+1)
                g_dct_res2[i][j] <= g_dct_res2[i][j+1];        // left shift g_dct_res2
            g_dct_res2[i][7] <= 0;
        end
    end
    
    // DCT phase 2 : left multiply DCTM
    // calculate when      g_cnt = 10~17, 18~25, 26~33, 34~41, 42~49, 50~57
    // produce result when g_cnt =    18,    26,    34,    42,    50,    58
    for (i=0; i<8; i=i+1) begin
        g_t2 = 0;
        for(k=0; k<8; k=k+1)
            g_t2 = g_t2 + (DCTM[i][k] * g_dct_res2[k][0]);
        g_t2 = (g_t2>>>(12+2*DCTP)) + g_t2[11+2*DCTP];
        g_dct_res3[i][7] <= $signed( g_t2[16:0] );                                            // push the DCT phase 2 result to the last column of g_dct_res3. = (g_t2 + 32768) / 65536
        for(j=0; j<7; j=j+1)
            g_dct_res3[i][j] <= g_dct_res3[i][j+1];                                           // left shift g_dct_res3
    end
    
    // save the 8x8 result of DCT phase 2, and do quantize by-the-way
    if( g_cnt == 6'd18 || g_cnt == 6'd26 || g_cnt == 6'd34 || g_cnt == 6'd42 || g_cnt == 6'd50 || g_cnt == 6'd58 )
        for (i=0; i<8; i=i+1)
            for (j=0; j<8; j=j+1) begin
                g_t3 = ( (g_dct_res3[i][j] < 0) ? -g_dct_res3[i][j] : g_dct_res3[i][j] );                  // y = abs(x)
                if( g_inter )                                                                              // inter block
                    g_t3 =   (g_t3 + 16'd2) >> (4 + Q_LEVEL);                                              //   y = (y+2) / 16 / (1<<Q_LEVEL)
                else if( i!=0 || j!=0 )                                                                    // intra block, AC value
                    g_t3 = ( (g_t3 + ((INTRA_Q[i][j]*((3<<Q_LEVEL)+2))>>3) ) >> Q_LEVEL ) / INTRA_Q[i][j]; //   y = ( y + (INTRA_Q*((3<<Q_LEVEL)+2)>>3) ) / (1<<Q_LEVEL) / INTRA_Q
                else                                                                                       // intra block, DC value
                    g_t3 = (g_t3>>4) + { 15'h0 , g_t3[3] } ;                                               //   y = (y/8 + 1) / 2
                if( g_t3 > 16'd2047 ) g_t3 = 16'd2047;                                                     // clip(y, 0, 2047)
                g_quant[i][j] <= (g_dct_res3[i][j] < 0) ? -$signed(g_t3[11:0]) : $signed(g_t3[11:0]);      // x = (y<0) ? -x : x;
            end
end





//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// stage H & J : inverse quantize, inverse DCT phase 1
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg          [       2:0] h_num_tile;
reg                       h_en  ;
reg          [       2:0] h_cnt ;
reg   signed [      12:0] h_iquant [0:7][0:7];         // 13 bit

reg   signed [      16:0] h_t1;                        // not real register

reg                       j1_en ;
reg          [       2:0] j1_num_tile ;
reg                       j1_en_tile ;
reg          [  32*9-1:0] j1_idct_x0_to_x8;

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        h_en <= 1'b0;
        h_cnt <= 3'd0;
        h_num_tile <= 3'd0;
        j1_en <= 1'b0;
        j1_num_tile <= 3'd0;
        j1_en_tile <= 1'b0;
    end else begin
        j1_en_tile <= 1'b0;
        if (g_en_tile) begin
            h_en <= 1'b1;
            h_cnt <= 3'd0;
            h_num_tile <= g_num_tile;
        end else begin
            h_cnt <= h_cnt + 3'd1;
            if(h_cnt == 3'b111)
                h_en <= 1'b0;
        end
        j1_en <= h_en;
        if(h_en) begin
            if(h_cnt == 3'b111) begin
                j1_en_tile  <= 1'b1;
                j1_num_tile <= h_num_tile;
            end
        end
    end

always @ (posedge clk)
    if(g_en_tile) begin
        for (i=0; i<8; i=i+1) begin
            for (j=0; j<8; j=j+1) begin
                h_t1 = g_quant[i][j];                                                                      // inverse quantize
                if( g_inter ) begin                                                                        // inter block
                    h_t1 = h_t1 << 1;                                                                      //   x *= 2
                    h_t1 = h_t1 + ( (h_t1<0) ? -17'sd1 : (h_t1>0) ? 17'sd1 : 17'sd0 );                     //   x += sign(x)
                    h_t1 = h_t1 << Q_LEVEL;                                                                //   x *= (1<<Q_LEVEL)
                    h_t1 = (h_t1 < -17'sd2047) ? -17'sd2047 : (h_t1 > 17'sd2047) ? 17'sd2047 : h_t1;       //   clip(x, -2047, 2047)
                end else if( i!=0 || j!=0 ) begin                                                          // intra block, AC value
                    h_t1 = h_t1 * INTRA_Q[i][j];                                                           //   x *= INTRA_Q
                    if( Q_LEVEL >= 3 )                                                                     //   x = x * (1<<Q_LEVEL) / 8
                        h_t1 = h_t1 << (Q_LEVEL - 3);                                                      //
                    else                                                                                   //
                        h_t1 = h_t1 >>> (3 - Q_LEVEL);                                                     //
                    h_t1 = (h_t1 < -17'sd2047) ? -17'sd2047 : (h_t1 > 17'sd2047) ? 17'sd2047 : h_t1;       //   clip(x, -2047, 2047)
                end else begin                                                                             // intra block, DC value
                    h_t1 = h_t1 << 1;                                                                      //   x *= 2
                end
                h_iquant[i][j] <= h_t1;
            end
        end
    end else begin
        for (j=0; j<8; j=j+1) begin
            for (i=0; i<7; i=i+1)
                h_iquant[i][j] <= h_iquant[i+1][j];               // up shift h_iquant by 1 step
            h_iquant[7][j] <= 13'd0;
        end
    end
    
always @ (posedge clk)
    if(h_en)                                                      // inverse DCT
        j1_idct_x0_to_x8 <= invserse_dct_rows_step12(h_iquant[0][0], h_iquant[0][1], h_iquant[0][2], h_iquant[0][3], h_iquant[0][4], h_iquant[0][5], h_iquant[0][6], h_iquant[0][7]);




// divide invserse_dct_rows to 2 pipeline stages : for better timing -----------------------------------------------------------------------------------------

reg          [       2:0] j_num_tile;
reg                       j_en_tile ;
reg   signed [      17:0] j_idct_res1 [0:7][0:7];

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        j_num_tile <= 3'd0;
        j_en_tile <= 1'b0;
    end else begin
        if (j1_en) begin
            j_num_tile <= j1_num_tile;
            j_en_tile <= j1_en_tile;
        end
    end

always @ (posedge clk)
    if (j1_en) begin
        {j_idct_res1[7][0], j_idct_res1[7][1], j_idct_res1[7][2], j_idct_res1[7][3], j_idct_res1[7][4], j_idct_res1[7][5], j_idct_res1[7][6], j_idct_res1[7][7]} <= invserse_dct_rows_step34(j1_idct_x0_to_x8);
        for (i=0; i<7; i=i+1)
            for (j=0; j<8; j=j+1)
                j_idct_res1[i][j] <= j_idct_res1[i+1][j];         // up shift j_idct_res1 by 1 step
    end






//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// stage K & M : inverse DCT phase 2
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg          [       2:0] k_num_tile;
reg                       k_en ;
reg          [       2:0] k_cnt;
reg   signed [      17:0] k_idct_res2 [0:7][0:7];

reg                       m1_en;
reg                       m1_idct_en3;
reg          [       2:0] m1_num_tile;
reg          [  32*9-1:0] m1_idct_x0_to_x8;

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        k_num_tile <= 3'd0;
        k_en <= 1'b0;
        k_cnt <= 3'd0;
        m1_en <= 1'b0;
        m1_idct_en3 <= 1'b0;
        m1_num_tile <= 3'd0;
    end else begin
        m1_idct_en3 <= 1'b0;
        if( j_en_tile ) begin
            k_num_tile <= j_num_tile;
            k_en  <= 1'b1;
            k_cnt <= 3'd0;
        end else begin
            k_cnt <= k_cnt + 3'd1;
            if(k_cnt == 3'b111)
                k_en <= 1'b0;
        end
        m1_en <= k_en;
        if(k_en) begin
            if(k_cnt == 3'b111) begin
                m1_idct_en3 <= 1'b1;
                m1_num_tile <= k_num_tile;
            end
        end
    end

always @ (posedge clk) begin                                      // for inverse DCT stage 2
    if( j_en_tile ) begin
        for (i=0; i<8; i=i+1)
            for (j=0; j<8; j=j+1)
                k_idct_res2[i][j] <= j_idct_res1[i][j];
    end else begin
        for (i=0; i<8; i=i+1) begin
            for (j=0; j<7; j=j+1)
                k_idct_res2[i][j] <= k_idct_res2[i][j+1];         // left shift k_idct_res2 for 2 steps
            k_idct_res2[i][7] <= 18'd0;
        end
    end
    if(k_en)
        m1_idct_x0_to_x8 <= invserse_dct_cols_step12(k_idct_res2[0][0], k_idct_res2[1][0], k_idct_res2[2][0], k_idct_res2[3][0], k_idct_res2[4][0], k_idct_res2[5][0], k_idct_res2[6][0], k_idct_res2[7][0]);
end



// divide invserse_dct_cols to 2 pipeline stages : for better timing -----------------------------------------------------------------------------------------

reg   signed [       8:0] m_idct_res3 [0:7][0:7];
reg                       m_idct_en3;
reg          [       2:0] m_num_tile;

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        m_idct_en3 <= 1'b0;
        m_num_tile <= 3'd0;
    end else begin
        if (m1_en) begin
            m_idct_en3 <= m1_idct_en3;
            m_num_tile <= m1_num_tile;
        end
    end

always @ (posedge clk)
    if (m1_en) begin
        {m_idct_res3[0][7], m_idct_res3[1][7], m_idct_res3[2][7], m_idct_res3[3][7], m_idct_res3[4][7], m_idct_res3[5][7], m_idct_res3[6][7], m_idct_res3[7][7]} <= invserse_dct_cols_step34(m1_idct_x0_to_x8);
        for (i=0; i<8; i=i+1)
            for (j=0; j<7; j=j+1)
                m_idct_res3[i][j] <= m_idct_res3[i][j+1];         // left shift m_idct_res3 by 1 step
    end






//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// stage N & P : 
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg          [  XB16-1:0] n_x16 ;
reg          [  YB16-1:0] n_y16 ;
reg          [       5:0] n_num_tiles_line ;

reg          [       7:0] n_tiles_prd [0:47][0:7];               // predicted block : Y/U/V tiles

reg   signed [       8:0] n_idct_res4 [0:7][0:7];
reg                       n_en ;
reg          [       2:0] n_cnt ;

reg          [   8*8-1:0] p_delay_mem_wdata;
reg                       p_en  ;
reg          [  XB16-1:0] p_x16 ;
reg          [  YB16-1:0] p_y16 ;
reg          [       5:0] p_num_tiles_line ;                     // 0~47

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        n_en  <= 1'b0;
        n_cnt <= 3'd0;
        p_en  <= 1'b0;
    end else begin
        if(m_idct_en3) begin
            n_en  <= 1'b1;
            n_cnt <= 3'd0;
        end else begin
            n_cnt <= n_cnt + 3'd1;
            if(n_cnt == 3'b111)
                n_en <= 1'b0;
        end
        p_en <= n_en;
    end

always @ (posedge clk) begin
    if(m_idct_en3) begin
        for (y=0; y<8; y=y+1)
            for (x=0; x<8; x=x+1)
                n_idct_res4[y][x] <= m_idct_res3[y][x];
    end else begin
        for (x=0; x<8; x=x+1) begin
            for (y=0; y<7; y=y+1)
                n_idct_res4[y][x] <= n_idct_res4[y+1][x];           // up shift n_idct_res4
            n_idct_res4[7][x] <= 9'd0;
        end
    end
    
    if(m_idct_en3 && (m_num_tile == 3'd0)) begin                    // for the first tile in a block, save the predicted block
        for (y=0; y<48; y=y+1)
            for (x=0; x<8; x=x+1)
                n_tiles_prd[y][x] <= g_tiles_prd[y][x];             // save the predicted block
        n_x16 <= g_x16;
        n_y16 <= g_y16;
        n_num_tiles_line <= 6'd0;
    end else if(n_en) begin
        for (y=0; y<47; y=y+1)
            for (x=0; x<8; x=x+1)
                n_tiles_prd[y][x] <= n_tiles_prd[y+1][x];           // up shift n_tiles_prd
        n_num_tiles_line <= n_num_tiles_line + 6'd1;
    end
    
    if(n_en) begin
        for (x=0; x<8; x=x+1)
            p_delay_mem_wdata[8*x+:8] <= add_clip_0_255( n_tiles_prd[0][x] , n_idct_res4[0][x] ) ;
        p_x16 <= n_x16;
        p_y16 <= n_y16;
        p_num_tiles_line <= n_num_tiles_line;
    end
end






//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// stage Q & R : use memory (mem_delay) to delay for a slice, and then write back to reference memory
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg          [   8*8-1:0] mem_delay [ 0 : ((48 * (XSIZE/16))-1) ];               // a memory to save a slice, to delay the write of mem_ref_Y & mem_ref_UV for a slice

always @ (posedge clk)
    if (p_en)
        mem_delay[{p_num_tiles_line, p_x16}] <= p_delay_mem_wdata;

reg          [   8*8-1:0] q_rd;
reg                       q_en  ;
reg          [  XB16-1:0] q_x16 ;
reg          [  YB16-1:0] q_y16 ;
reg          [       5:0] q_num_tiles_line ;

reg          [   8*8-1:0] r_rd;
reg                       r_en  ;
reg          [  XB16-1:0] r_x16 ;
reg          [  YB16-1:0] r_y16 ;
reg          [       5:0] r_num_tiles_line ;

always @ (posedge clk)
    q_rd <= mem_delay[{p_num_tiles_line, p_x16}];

always @ (posedge clk)
    r_rd <= q_rd;

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        q_en  <= 1'b0;
        q_x16 <= 0;
        q_y16 <= 0;
        q_num_tiles_line <= 6'd0;
    end else begin
        q_en  <= p_en;
        q_x16 <= p_x16;
        q_y16 <= p_y16;
        q_num_tiles_line <= p_num_tiles_line;
    end

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        r_en  <= 1'b0;
        r_x16 <= 0;
        r_y16 <= 0;
        r_num_tiles_line <= 6'd0;
    end else begin
        r_en  <= q_en;
        r_x16 <= q_x16;
        r_y16 <= (q_y16 == 0) ? max_y16 : (q_y16 - 1) ;         // set the write block to the upper slice
        r_num_tiles_line <= q_num_tiles_line;
    end

always @ (posedge clk)
    if( r_en && ~r_num_tiles_line[5] )
        mem_ref_Y [ {r_y16, r_num_tiles_line[4], r_num_tiles_line[2:0], r_x16, r_num_tiles_line[3]} ] <= r_rd;      // write to Y reference frame memory

always @ (posedge clk)
    if( r_en &&  r_num_tiles_line[5] )
        mem_ref_UV[ {r_y16                     , r_num_tiles_line[2:0], r_x16, r_num_tiles_line[3]} ] <= r_rd;      // write to U/V reference frame memory


//reg [8*8-1:0] mem_ref_Y  [ (YSIZE  ) * (XSIZE/8 )     ];   //   Y reference frame memory : (YSIZE  ) rows, XSIZE/8  cols                  , each item contains  8 Y pixels
//reg [8*8-1:0] mem_ref_UV [ (YSIZE/2) * (XSIZE/16) * 2 ];   // U/V reference frame memory : (YSIZE/2) rows, XSIZE/16 cols, 2 channels (U/V), each item contains  8 U or V pixels





//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// stage S : zig-zag reorder, generate nzflags
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg                       s_nzflag ;                    // temporary variable
reg          [       5:0] s_nzflags ;
reg   signed [      11:0] s_zig_blk [0:5] [0:63];       // 12 bit
reg                       s_en_blk ;

always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        s_en_blk <= 1'b0;
    end else begin
        s_en_blk <= 1'b0;
        if(g_en_tile)
            s_en_blk <= ( g_num_tile == 3'd5 );                             // is the last tile in a block ?
    end

always @ (posedge clk)
    if(g_en_tile) begin
        for (i=0; i<64; i=i+1) begin
            s_zig_blk[0][i] <= s_zig_blk[1][i];
            s_zig_blk[1][i] <= s_zig_blk[2][i];
            s_zig_blk[2][i] <= s_zig_blk[3][i];
            s_zig_blk[3][i] <= s_zig_blk[4][i];
            s_zig_blk[4][i] <= s_zig_blk[5][i];
        end
        s_nzflag = ~g_inter;
        for (i=0; i<8; i=i+1)
            for (j=0; j<8; j=j+1) begin
                s_zig_blk[5][ZIGZAG[i][j]] <= g_quant[i][j];                // zig-zag reorder
                s_nzflag = s_nzflag | (g_quant[i][j] != 12'd0);             // check if g_quant are all zero
            end
        s_nzflags <= {s_nzflags[4:0], s_nzflag};
    end







//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// stage T : MPEG2 stream generation
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg          [       5:0] t_frame_hour, t_frame_minute, t_frame_second, t_frame_insec;    // (hour,minute,second,insec) = (0~63,0~59,0~59,0~23)

reg          [       7:0] t_i_frame ;
reg          [  XB16-1:0] t_x16 ;
reg          [  YB16-1:0] t_y16 ;
reg                       t_inter ;
reg          [       5:0] t_nzflags ;
reg   signed [       4:0] t_mvx, t_mvy;
reg   signed [       4:0] t_prev_mvx, t_prev_mvy;
reg   signed [      11:0] t_zig_blk [0:5] [0:63];
reg   signed [      11:0] t_prev_Y_dc, t_prev_U_dc, t_prev_V_dc;
reg          [       5:0] t_runlen ;

reg          [       2:0] t_num_tile ;
reg          [       3:0] t_cnt ;

localparam   [       2:0] PUT_ENDED        = 3'd0,
                          PUT_SEQ_HEADER2  = 3'd1,
                          PUT_IDLE         = 3'd2,
                          PUT_FRAME_HEADER = 3'd3,
                          PUT_SLICE_HEADER = 3'd4,
                          PUT_BLOCK_INFO   = 3'd5,
                          PUT_TILE         = 3'd6;

reg          [       2:0] t_stat = PUT_ENDED;

//enum reg     [       2:0] {PUT_ENDED, PUT_SEQ_HEADER2, PUT_IDLE, PUT_FRAME_HEADER, PUT_SLICE_HEADER, PUT_BLOCK_INFO, PUT_TILE} t_stat;

reg                       t_end_seq ;
reg                       t_align ;
reg          [      23:0] t_bits [0:6];
reg          [       4:0] t_lens [0:6];
reg                       t_append_b10 ;


reg   signed [       6:0] dmv;         // temporary variable, not real register
reg          [       4:0] dmvabs;      // temporary variable, not real register
reg                       nzflag;      // temporary variable, not real register
reg   signed [      11:0] val;         // temporary variable, not real register
reg   signed [      12:0] diff_dc;     // temporary variable, not real register
reg          [      11:0] tmp_val;     // temporary variable, not real register
reg          [       3:0] vallen;      // temporary variable, not real register
reg          [       5:0] runlen;      // temporary variable, not real register


function [24+5-1:0] put_AC;
    input signed [11:0] v;
    input        [ 5:0] rl;
//function automatic logic [24+5-1:0] put_AC (input logic signed [11:0] v, input logic [5:0] rl);        // because of run-length encoding, v cannot be zero
    reg [23:0] bits;
    reg [ 4:0] lens;
    reg [10:0] absv;
begin
    absv = (v < 12'sd0) ? ($unsigned(-v)) : ($unsigned(v));
    absv = absv - 1;
    if ( rl == 0 && absv < 40 || rl == 1 && absv < 18 || rl == 2 && absv < 5 || rl == 3 && absv < 4 ) begin
        bits = { BITS_AC_0_3[rl][absv], (v<12'sd0)?1'b1:1'b0 };
        lens =   LENS_AC_0_3[rl][absv] + 5'd1;
    end else if( rl <= 6 && absv < 3 || rl <= 16 &&  absv < 2 || rl <= 31 &&  absv < 1 ) begin
        bits = {BITS_AC_4_31[rl][absv], (v<12'sd0)?1'b1:1'b0 };
        lens =  LENS_AC_4_31[rl][absv] + 5'd1;
    end else begin
        bits = { 6'h1, rl, $unsigned(v) };
        lens = 5'd24;
    end
    put_AC = {bits, lens};
end
endfunction


always @ (posedge clk or negedge rstn)
    if (~rstn) begin
        {t_frame_hour, t_frame_minute, t_frame_second, t_frame_insec} <= 0;
        t_i_frame <= 0;
        t_x16 <= 0;
        t_y16 <= 0;
        t_inter <= 0;
        t_nzflags <= 0;
        t_mvx <= 0;
        t_mvy <= 0;
        t_prev_mvx <= 0;
        t_prev_mvy <= 0;
        {t_prev_Y_dc, t_prev_U_dc, t_prev_V_dc} <= 0;
        t_runlen <= 0;
        t_num_tile <= 0;
        t_cnt <= 0;
        t_stat <= PUT_ENDED;
        
        t_end_seq <= 0;
        t_align <= 0;
        for(i=0; i<7; i=i+1) begin
            t_bits[i] <= 0;
            t_lens[i] <= 0;
        end
        t_append_b10 <= 0;
    end else begin
        t_runlen <= 0;
        
        t_num_tile <= 0;
        t_cnt <= 0;
        
        t_end_seq <= 0;
        t_align <= 0;
        for(i=0; i<7; i=i+1) begin
            t_bits[i] <= 0;
            t_lens[i] <= 0;
        end
        t_append_b10 <= 0;
        
        case(t_stat)
            PUT_ENDED : begin
                if(sequence_start) begin
                    t_stat <= PUT_SEQ_HEADER2;
                    
                    {t_frame_hour, t_frame_minute, t_frame_second, t_frame_insec} <= 0;                        // clear time code
                    
                    t_align <= 1'b1;
                    
                    t_bits[0] <=         'h000001;    t_lens[0] <= 24;                                         // sequence header : part 1 (152 bits)
                    t_bits[1] <=             'hB3;    t_lens[1] <=  8;
                    t_bits[2] <= {size_x, size_y};    t_lens[2] <= 24;
                    t_bits[3] <=         'h1209c4;    t_lens[3] <= 24;
                    t_bits[4] <=         'h200000;    t_lens[4] <= 24;
                    t_bits[5] <=         'h0001B5;    t_lens[5] <= 24;
                    t_bits[6] <=         'h144200;    t_lens[6] <= 24;
                end
            end
            
            PUT_SEQ_HEADER2 : begin
                t_stat <= PUT_IDLE;
                
                t_bits[0] <=         'h010000;    t_lens[0] <= 24;                                            // sequence header : part 2 (117 bits)
                t_bits[1] <=         'h000001;    t_lens[1] <= 24;
                t_bits[2] <=         'hB52305;    t_lens[2] <= 24;
                t_bits[3] <=           'h0505;    t_lens[3] <= 16;
                t_bits[4] <=           size_x;    t_lens[4] <= 14;
                t_bits[5] <=             1'b1;    t_lens[5] <=  1;
                t_bits[6] <=           size_y;    t_lens[6] <= 14;
            end
            
            PUT_IDLE : begin
                if( t_y16 == max_y16 && t_x16 == max_x16 && sequence_state == SEQ_ENDED) begin
                    t_stat <= PUT_ENDED;
                    t_end_seq <= 1'b1;
                    t_align <= 1'b1;
                    t_bits[0] <= 'h000001;
                    t_lens[0] <= 24;
                    t_bits[1] <= 'hB7;                                                                          // sequence end
                    t_lens[1] <= 8;
                    
                end else if( s_en_blk ) begin
                    t_i_frame <= g_i_frame;
                    t_y16 <= g_y16;
                    t_x16 <= g_x16;
                    t_inter <= g_inter;
                    t_mvx <= g_mvx;
                    t_mvy <= g_mvy;
                    t_nzflags <= s_nzflags;
                    
                    t_stat <= PUT_BLOCK_INFO;
                    
                    if( g_x16 == 0 ) begin                            // start of slice
                        t_stat <= PUT_SLICE_HEADER;
                        if( g_y16 == 0 ) begin                        // start of frame
                            t_stat <= PUT_FRAME_HEADER;
                            if( g_i_frame == 8'd0 ) begin             // start of GOP
                                t_align <= 1'b1;
                                //t_bits <= '{ 'h000001, 'hB8, t_frame_hour, t_frame_minute, {1'b1, t_frame_second}, t_frame_insec, 'h2 };   // GOP header (59 bits)
                                //t_lens <= '{       24,    8,            6,              6,                      7,             6,   2 };
                                
                                t_bits[0] <=         'h000001;    t_lens[0] <= 24;                                         // GOP header (59 bits)
                                t_bits[1] <=             'hB8;    t_lens[1] <=  8;
                                t_bits[2] <=     t_frame_hour;    t_lens[2] <=  6;
                                t_bits[3] <=   t_frame_minute;    t_lens[3] <=  6;
                                t_bits[4]<={1'b1,t_frame_second}; t_lens[4] <=  7;
                                t_bits[5] <=    t_frame_insec;    t_lens[5] <=  6;
                                t_bits[6] <=              'h2;    t_lens[6] <=  2;
                            end
                        end
                    end
                end
            end
            
            PUT_FRAME_HEADER : begin
                t_stat <= PUT_SLICE_HEADER;
                
                t_align <= 1'b1;
                //t_bits <= '{ 'h000001, t_i_frame, 'h10000, 'h0, 'h000001, 'hB58111, 'h1BC000 };       // frame header (136 bits for I-frame, 144 bits for P-frame)
                //t_lens <= '{       24,        18,      19,   3,       24,       24,       24 };
                
                t_bits[0] <=         'h000001;    t_lens[0] <= 24;                                      // frame header (136 bits for I-frame, 144 bits for P-frame)
                t_bits[1] <=        t_i_frame;    t_lens[1] <= 18;
                t_bits[2] <=          'h10000;    t_lens[2] <= 19;
                t_bits[3] <=              'h0;    t_lens[3] <=  3;
                t_bits[4] <=         'h000001;    t_lens[4] <= 24;
                t_bits[5] <=         'hB58111;    t_lens[5] <= 24;
                t_bits[6] <=         'h1BC000;    t_lens[6] <= 24;
                
                if ( t_i_frame != 8'd0 ) begin   // for P-frame
                    t_bits[2] <= 'h20000;
                    t_bits[3] <=   'h380;
                    t_lens[3] <=      11;
                end
                
                // for new frame, update time code ---------------------------
                t_frame_insec <= t_frame_insec + 6'd1;
                if( t_frame_insec == 6'd23 ) begin
                    t_frame_insec <= 6'd0;
                    t_frame_second <= t_frame_second + 6'd1;
                    if( t_frame_second == 6'd59 ) begin
                        t_frame_second <= 6'd0;
                        t_frame_minute <= t_frame_minute + 6'd1;
                        if( t_frame_minute == 6'd59 ) begin
                            t_frame_minute <= 6'd0;
                            if( t_frame_hour < 6'd63 )
                                t_frame_hour <= t_frame_hour + 6'd1;
                        end
                    end
                end
            end
            
            PUT_SLICE_HEADER : begin
                t_stat <= PUT_BLOCK_INFO;
                
                t_align <= 1'b1;
                //t_bits <= '{ 'h000001, 1+t_y16, (2<<Q_LEVEL), 'h0, 'h0, 'h0, 'h0 };     // slice header : 38 bits
                //t_lens <= '{       24,       8,            6,   0,   0,   0,   0 };
                
                t_bits[0] <=         'h000001;    t_lens[0] <= 24;                        // slice header : 38 bits
                t_bits[1] <=        (1+t_y16);    t_lens[1] <=  8;
                t_bits[2] <=     (2<<Q_LEVEL);    t_lens[2] <=  6;
                
                // for new slice, clear the previous DC value and the previous motion vector ---------------------------
                {t_prev_Y_dc, t_prev_U_dc, t_prev_V_dc} <= 0;
                t_prev_mvx <= 0;
                t_prev_mvy <= 0;
            end
            
            PUT_BLOCK_INFO : begin
                t_stat <= PUT_TILE;
                
                // put block type -----------------------------------------------------------------------------------------
                if          ( ~t_inter && t_i_frame != 0 ) begin      // intra block in a P-frame
                    t_bits[0] <= 'h23;
                    t_lens[0] <= 6;
                end else if (  t_inter && t_nzflags == 0 ) begin      // inter block with all zeros
                    t_bits[0] <= 'h09;
                    t_lens[0] <= 4;
                end else begin                                         // otherwise (the most case)
                    t_bits[0] <= 'h03;
                    t_lens[0] <= 2;
                end
                
                // for inter block, put motion vector and nzflags ------------------------------------------------------------------
                if( t_inter ) begin
                    // put motion vector x ------------------------------------------------------------------
                    dmv = t_mvx;
                    dmv = dmv - t_prev_mvx;
                    if      (dmv > 7'sd15)
                        dmv = dmv - 7'sd32;
                    else if (dmv < -7'sd16)
                        dmv = dmv + 7'sd32;
                    dmvabs = (dmv < 7'sd0) ? ($unsigned(-dmv)) : ($unsigned(dmv)) ;
                    t_bits[1] <= BITS_MOTION_VECTOR[dmvabs];
                    t_lens[1] <= LENS_MOTION_VECTOR[dmvabs];
                    if (dmv != 7'sd0) begin
                        t_bits[2] <= (dmv < 7'sd0) ? 1'b1 : 1'b0;
                        t_lens[2] <= 1;
                    end
                    
                    // put motion vector y ------------------------------------------------------------------
                    dmv = t_mvy;
                    dmv = dmv - t_prev_mvy;
                    if      (dmv > 7'sd15)
                        dmv = dmv - 7'sd32;
                    else if (dmv < -7'sd16)
                        dmv = dmv + 7'sd32;
                    dmvabs = (dmv < 7'sd0) ? ($unsigned(-dmv)) : ($unsigned(dmv)) ;
                    t_bits[3] <= BITS_MOTION_VECTOR[dmvabs];
                    t_lens[3] <= LENS_MOTION_VECTOR[dmvabs];
                    if (dmv != 7'sd0) begin
                        t_bits[4] <= (dmv < 7'sd0) ? 1'b1 : 1'b0;
                        t_lens[4] <= 1;
                    end
                    
                    // put nzflags ------------------------------------------------------------------
                    t_bits[5] <= BITS_NZ_FLAGS[t_nzflags];
                    t_lens[5] <= LENS_NZ_FLAGS[t_nzflags];
                    
                    t_prev_mvx <= t_mvx;
                    t_prev_mvy <= t_mvy;
                end else begin            // for intra block, clear the previous motion vector
                    t_prev_mvx <= 0;
                    t_prev_mvy <= 0;
                end
            end
            
            default : begin  // PUT_TILE : begin
                
                nzflag = t_nzflags[5];
                
                if (t_cnt == 4'd0) begin                                                                               // DC value
                    val = t_zig_blk[0][0];                                                                             // val <- DC value
                    diff_dc = val;
                    if          (t_num_tile <  3'd4) begin
                        diff_dc = diff_dc - t_prev_Y_dc;
                        t_prev_Y_dc <= t_inter ? 12'd0 : val;                                                          // save the DC value as the previous Y DC value for next tile
                    end else if (t_num_tile == 3'd4) begin
                        diff_dc = diff_dc - t_prev_U_dc;
                        t_prev_U_dc <= t_inter ? 12'd0 : val;                                                          // save the DC value as the previous U DC value for next tile
                    end else begin
                        diff_dc = diff_dc - t_prev_V_dc;
                        t_prev_V_dc <= t_inter ? 12'd0 : val;                                                          // save the DC value as the previous V DC value for next tile
                    end
                    
                    if (t_inter) begin                                                                                 // put DC value (INTER)
                        if (val == 0) begin
                            t_runlen <= 6'd1;
                        end else if( val == 12'sd1 || val == -12'sd1 ) begin
                            if (nzflag) begin
                                t_bits[0] <= { 1'b1, (val<12'sd0) ? 1'b1 : 1'b0 };
                                t_lens[0] <= 2;
                            end
                        end else begin
                            if (nzflag)
                                {t_bits[0], t_lens[0]} <= put_AC(val, 6'd0);
                        end
                    end else begin                                                                                     // put DC value (INTRA)
                        tmp_val = $unsigned( (diff_dc < 13'sd0) ? -diff_dc : diff_dc );
                        vallen = 4'd0;
                        for (i=0; i<12; i=i+1)
                            if (tmp_val[i])
                                vallen = (i+1);
                        tmp_val = $unsigned(diff_dc);
                        if (diff_dc < 13'sd0)
                            tmp_val = tmp_val + ((12'd1 << vallen) - 12'd1);
                        if (nzflag) begin
                            t_bits[0] <= (t_num_tile < 3'd4) ? BITS_DC_Y[vallen] : BITS_DC_UV[vallen];
                            t_lens[0] <= (t_num_tile < 3'd4) ? LENS_DC_Y[vallen] : LENS_DC_UV[vallen];
                            t_bits[1] <= tmp_val;
                            t_lens[1] <= vallen;
                        end
                    end
                end else begin                                                                                          // AC value
                    runlen = t_runlen;
                    for(i=0; i<7; i=i+1) begin
                        val = t_zig_blk[0][i+1];
                        if (val != 12'sd0) begin
                            if (nzflag)
                                {t_bits[i], t_lens[i]} <= put_AC(val, runlen);
                            runlen = 6'd0;
                        end else
                            runlen = runlen + 6'd1;
                    end
                    t_runlen <= runlen;
                    t_append_b10 <= nzflag && (t_cnt == 4'd9);                                                          // for the last cycle of a tile, append 2'b10 to the MPEG2 stream
                end
                
                if (t_cnt < 4'd9) begin                                                                                 // NOT the last cycle of a tile
                    t_cnt <= t_cnt + 4'd1;
                    t_num_tile <= t_num_tile;
                end else begin                                                                                          // the last cycle of a tile
                    t_num_tile <= t_num_tile + 3'd1;
                    if (t_num_tile == 3'd5)                                                                             // the last tile
                        t_stat <= PUT_IDLE;                                                                             // end of this block, return to IDLE
                    t_nzflags <= (t_nzflags << 1);
                end
            end
        endcase
    end


always @ (posedge clk)
    case(t_stat)
        PUT_IDLE : begin
            if( s_en_blk ) begin
                for(i=0; i<6; i=i+1)
                    for(j=0; j<64; j=j+1)
                        t_zig_blk[i][j] <= s_zig_blk[i][j];
            end
        end

        PUT_TILE : begin
            if          (t_cnt == 4'd0) begin                                                                       // DC value
            end else if (t_cnt < 4'd9) begin                                                                        // NOT the last cycle of a tile
                for (i=1; i<=56; i=i+1)
                    t_zig_blk[0][i] <= t_zig_blk[0][i+7];                                                           // shift AC values for 7 steps
            end else begin                                                                                          // the last cycle of a tile
                for(i=0; i<5; i=i+1)                                                                              // switch the tiles
                    for(j=0; j<64; j=j+1)
                        t_zig_blk[i][j] <= t_zig_blk[i+1][j];
            end
        end
    endcase





reg          [     169:0] u_bits ;         // max 170 bits
reg          [       7:0] u_lens ;         // 0~170
reg                       u_align ;
reg                       u_end_seq1 ;
reg                       u_end_seq2 ;

reg          [     169:0] ut_bits;             // temporary variable, not real register
reg          [       7:0] ut_lens;             // temporary variable, not real register

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        u_bits <= 0;
        u_lens <= 0;
        u_align <= 0;
        {u_end_seq2, u_end_seq1} <= 0;
    end else begin
        ut_bits = 0;
        ut_lens = 0;
        if (t_append_b10) begin
            ut_bits = 170'b10;
            ut_lens = ut_lens + 8'd2;
        end
        for (i=6; i>=0; i=i-1) begin
            ut_bits = ut_bits | ( {146'd0, t_bits[i]} << ut_lens );
            ut_lens = ut_lens + t_lens[i];
        end
        u_bits <= ut_bits;
        u_lens <= ut_lens;
        u_align <= t_align;
        {u_end_seq2, u_end_seq1} <= {u_end_seq1, t_end_seq};
    end




reg          [     254:0] v_bits ;     // max 255 bits
reg          [       7:0] v_lens ;     // 0~255

reg          [     255:0] v_data ;
reg                       v_en ;
reg                       v_last ;

reg          [     431:0] vt_bits;         // 432 bits, temporary variable, not real register
reg          [       8:0] vt_lens;         // temporary variable, not real register

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        v_bits <= 0;
        v_lens <= 0;
        v_data <= 0;
        v_en   <= 0;
        v_last <= 0;
    end else begin
        if (u_end_seq2) begin                            // a special case: end of sequence
            v_bits <= 0;
            v_lens <= 0;
            v_data <= {v_bits, 1'b0};
            v_en <= 1'b1;
            v_last <= 1'b1;
        end else begin
            vt_lens = {1'b0, v_lens};
            if (u_align && vt_lens[2:0] != 3'h0) begin
                vt_lens[2:0] = 3'd0;
                vt_lens[8:3] = vt_lens[8:3] + 6'd1;      // align lens to a multiple of 8 bits (1 byte)
            end
            vt_lens = vt_lens + {1'h0, u_lens};
            vt_bits = {v_bits, 177'h0}  |  ( {262'h0, u_bits} << (9'd432-vt_lens) );
            v_lens <= vt_lens[7:0];
            if (vt_lens[8]) begin
                {v_data, v_bits} <= {vt_bits, 79'h0};
                v_en <= 1'b1;
            end else begin
                v_bits <= vt_bits[431:177];
                v_en <= 1'b0;
            end
            v_last <= 1'b0;
        end
    end




assign o_en   = v_en;
assign o_last = v_last;
assign o_data = {   v_data[  0 +: 8],      // convert BIG ENDIAN to LITTLE ENDIAN
                    v_data[  8 +: 8],
                    v_data[ 16 +: 8],
                    v_data[ 24 +: 8],
                    v_data[ 32 +: 8],
                    v_data[ 40 +: 8],
                    v_data[ 48 +: 8],
                    v_data[ 56 +: 8],
                    v_data[ 64 +: 8],
                    v_data[ 72 +: 8],
                    v_data[ 80 +: 8],
                    v_data[ 88 +: 8],
                    v_data[ 96 +: 8],
                    v_data[104 +: 8],
                    v_data[112 +: 8],
                    v_data[120 +: 8],
                    v_data[128 +: 8],
                    v_data[136 +: 8],
                    v_data[144 +: 8],
                    v_data[152 +: 8],
                    v_data[160 +: 8],
                    v_data[168 +: 8],
                    v_data[176 +: 8],
                    v_data[184 +: 8],
                    v_data[192 +: 8],
                    v_data[200 +: 8],
                    v_data[208 +: 8],
                    v_data[216 +: 8],
                    v_data[224 +: 8],
                    v_data[232 +: 8],
                    v_data[240 +: 8],
                    v_data[248 +: 8] };


endmodule




