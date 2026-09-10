from pathlib import Path

f_data = Path('sprite_data.bin').read_bytes()

spr_num = 0
spr_list = []
while f_data:

    spr_w_f = f_data[0]
    spr_h = f_data[1]
    f_data = f_data[2:]

    spr_w = spr_w_f & 0x1f

    spr_list.append("sprite_{:03}".format(spr_num))
    print("\t\t\tALIGN 4") # we can align on 4 byte boundary so we can use INC L / DEC L to move between width, height and start of mask/data
    print(spr_list[-1]+':')
    spr_num += 1

    #print("\t\t\tDB\t{},{}".format(spr_w * 8, spr_h))
    print("\t\t\tDB\t{},{}".format((spr_w - 2) * 32, spr_h)) 

    num_bytes = spr_w * spr_h * 2
    spr_bytes = f_data[:num_bytes]

    spr_mask_bytes = list(spr_bytes[0::2])     # mask
    spr_data_bytes = list(spr_bytes[1::2])     # data

    # split sprite data and mask into rows
    spr_mask_list = [spr_mask_bytes[i : i + spr_w] for i in range(0, len(spr_mask_bytes), spr_w)]  
    spr_data_list = [spr_data_bytes[i : i + spr_w] for i in range(0, len(spr_data_bytes), spr_w)]  

    # reverse as binary data is upside down (as per usual for Ultimate)
    spr_mask_list.reverse()
    spr_data_list.reverse()

    for spr_data,spr_mask in zip(spr_data_list,spr_mask_list):

        # generate comment 
        c = ''        
        for d,m in zip(spr_data, spr_mask):
            m_bits = "{0:08b}".format(255 ^ m)
            d_bits = "{0:08b}".format(d)
            for b in range(0, 8):
                ms = m_bits[b]
                ds = d_bits[b]
                c += '  ' if ms == '1' else '..' if ds == '0' else '##'

        # generate data + mask interleaved
        print('\t\t\tDB\t' + ','.join(['0b{0:08b},0b{1:08b}'.format(255^m,d) for d,m in zip(spr_data, spr_mask)]) + ' ;' + c)                

        #print('\t\t\tDB\t' + ','.join(['0b{0:08b}'.format(x) for x in spr_data]) + ' ;' + c)

    # mask data
    #for spr_data,spr_mask in zip(spr_data_list,spr_mask_list):
    #    print('\t\t\tDB\t' + ','.join(['0b{0:08b}'.format(255 ^ x) for x in spr_mask]))

    f_data = f_data[num_bytes:]

print("\t\t\tALIGN\t256")
print("sprite_table:")
for l in [spr_list[i:i + 4] for i in range(0, len(spr_list), 4)]:
    print('\t\t\tDW\t' + ', '.join(l))
