#!/usr/bin/python3 -u

import os
import sys
import pathlib
import argparse
import re
import string
import sqlite3 as sql
from pprint import pprint
from Bio import SeqIO
from collections import defaultdict, namedtuple
from operator import itemgetter
from termcolor import colored

class Transfer:
    def __init__(self, oldname, oldstart, oldend, newname, newstart, newend, strand, parttype="active"):
        self.oldname = oldname
        self.oldstart = int(oldstart)
        self.oldend = int(oldend)
        self.newname = newname
        self.newstart = int(newstart)
        self.newend = int(newend)
        self.strand = int(strand)
        self.parttype = parttype
    
    def __repr__(self):
        return '{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}'.format(self.oldname, self.oldstart, self.oldend, self.newname, self.newstart, self.newend, self.strand, self.parttype)
        
def load_genome(fasta):
    try:
        with open(fasta, 'r') as f:
            sequences = SeqIO.to_dict(SeqIO.parse(f, "fasta"))
    except IOError:
        print("Can't load genome from file {}!".format(fasta))
        sys.exit()

    transfer = defaultdict(lambda: defaultdict(Transfer))
    for scaffold in sequences:
        end = len(sequences[scaffold])
        transfer[scaffold][1] = Transfer(scaffold, 1, end, scaffold, 1, end, 1, "active")
    return sequences, transfer

class Correction:
    def __init__(self, scaffold, start, end, breaktype, details=""):
        self.scaffold = scaffold
        self.start = int(start)
        self.end = int(end)
        self.breaktype = breaktype
        self.details = details

    def __repr__(self):
        return '{}\t{}\t{}\t{}\t{}'.format(self.scaffold, self.start, self.end, self.breaktype, self.details)
    
    def update(self, newname, newstart, lastpart):
        self.scaffold = newname
        self.start = newstart - 1 + self.start
        self.end = newstart - 1 + self.end
        if self.breaktype == 'B':
            self.details = newstart - 1 + int(self.details)
        elif (self.breaktype == 'R' or self.breaktype == 'K') and '-' in self.details:
            oldstart, oldend = self.details.split('-')
            self.details = '{}-{}'.format(newstart -1 + int(oldstart), newstart-1 + int(oldend))
        elif self.breaktype == 'R':
            self.details = '+'.join([str(int(p)+lastpart) for p in self.details.split('+')])
        else:
            pass
            

        
def load_corrections(correctfile, genome):
    corrections = defaultdict(lambda: defaultdict(Correction))
    try:
        with open(correctfile, 'r') as c:
            for line in c:
                mode, scaffold, start, end, breaktype, *args = line.rstrip().split('\t')
                if args:
                    details = args[0]
                if end == "End":
                    end = len(genome[scaffold])
                corrections[scaffold][int(start)] = Correction(scaffold, start, end, breaktype, details)
        return corrections
    except IOError:
        print("Can't open corrections file", corrections)
        sys.exit()


class AGP:
    def __init__(self, scaffold, start, end, part, parttype):
        self.scaffold = scaffold
        self.start = int(start)
        self.end = int(end)
        self.part = int(part)
        self.parttype = parttype
        
    def __repr__(self):
        return '{}\t{}\t{}\t{}\t{}\t{}'.format(self.scaffold, self.start, self.end, self.part, self.parttype, self.length)
    
    def update(self, lastend, lastpart):
        self.part = self.part + lastpart
        self.start = self.start + lastend
        self.end = self.end + lastend
        
    @property
    def length(self):
        return self.end-self.start+1

def load_broken_scaffolds(agp, real_breakage_file):
    
    real_breakages = {}
    try:
        with open(real_breakage_file, 'r') as r:
            for line in r:
                scaffold = line.rstrip()
                real_breakages[scaffold] = 0
    except IOError:
        print("Can't open real breakages file", real_breakages)
        sys.exit()
    
    scaffolds = defaultdict(lambda: defaultdict(AGP))
    broken_scaffolds = {}
    try:
        with open(agp, 'r') as a:
            for line in a:
                scaffold, start, end, part, parttype, *args = line.rstrip().split('\t')
                scaffolds[scaffold][int(start)] = AGP(scaffold, start, end, part, parttype)
                if ':' in args[-1]:
                    old_scaffold, start, end, part = args[-1].split(':')
                    if old_scaffold not in broken_scaffolds:
                        broken_scaffolds[old_scaffold] = {}
                    if scaffold not in broken_scaffolds[old_scaffold]:
                        broken_scaffolds[old_scaffold][scaffold] = 'Merge'
                    if scaffold in real_breakages:
                        broken_scaffolds[old_scaffold][scaffold] = 'Break'
            return scaffolds, broken_scaffolds
    except IOError:
        print("Can't open AGP file", agp)
        sys.exit()

def move_agp(a, b, newname, newstart, agp):

    # Get last part and transfer first scaffold to new scaffold
    if a != newname:
        agp[newname] = agp[a]
        del agp[a]

    lastpart = agp[newname][max(agp[newname])].part

    # Add gap
    agp[newname][newstart] = AGP(newname, newstart, newstart+99, lastpart+1, "N")
    lastpart += 1
    newstart += 100

    # Add second scaffold, updating positions and parts
    lastend = newstart - 1
    for start in sorted(agp[b]):
        nextstart = lastend + start
        agp[b][start].update(lastend, lastpart)
        agp[newname][nextstart] = agp[b][start]
    del agp[b]
    
    # Change name of parts to new scaffold
    for start in sorted(agp[newname]):
        agp[newname][start].scaffold=newname

    return lastpart

def move_corrections(oldname, newname, newstart, lastpart, corrections, log):

    log.write("\tMoving corrections for {} to {} with start {}, part {}\n".format(oldname, newname, newstart, lastpart))
    corrections_to_remove = []
    for oldstart in corrections[oldname]:
        cor = corrections[oldname][oldstart]
        cor.update(newname, newstart, lastpart)
        corrections[newname][newstart] = cor
        corrections_to_remove.append(oldstart)

    for oldstart in corrections_to_remove:
        del(corrections[oldname][oldstart])
    if not corrections[oldname]:
        del corrections[oldname]

def write_transfer(t, transfer):
    print("Transfer", t)
    for start in sorted(transfer[t]):
        print("\tStart", start)
        print("\t", t, start, transfer[t][start])
    print('--------------------------')

def merge_transfer(a, b, newname, transfer):
    if a != newname:
        for start in sorted(transfer[a]):
            at = transfer[a][start]
            transfer[newname][start] = Transfer(a, start, at.newend, newname, start, at.newend, at.strand, at.parttype)
        del transfer[a]

    lastend = transfer[newname][max(transfer[newname])].newend + 100
    for start in sorted(transfer[b]):
        bt = transfer[b][start]
        newstart = lastend+start
        newend = lastend + bt.newend
        transfer[newname][newstart] = Transfer( b, start, bt.newend, newname, newstart, newend, bt.strand, bt.parttype)

    del transfer[b]
    
def merge_broken(broken_scaffolds, genome, agp, corrections, transfer, log):
    
    newnumber = 679999
    for old in sorted(broken_scaffolds):
        news = sorted(broken_scaffolds[old])
        if len(news) == 1:
            continue
        last_merge = None
        for i, new in enumerate(news):
            if broken_scaffolds[old][new] == 'Merge' and i < len(news)-1:
                next_scaffold = news[i+1]
                log.write("Merging {} and {}\n".format(new, next_scaffold))
                if new not in genome and last_merge:
                    log.write("\t{} already merged into {}\n".format(new, last_merge))
                    new = last_merge

                if last_merge:
                    newname = last_merge
                else:
                    newnumber += 1
                    newname = "HE" + str(newnumber)

                newstart = len(genome[new]) + 1

                genome[newname] = genome[new] + 'N' * 100 + genome[next_scaffold]
                genome[newname].id = genome[newname].description = genome[newname].name = newname
                
                lastpart = move_agp(new, next_scaffold, newname, newstart, agp)
                merge_transfer(new, next_scaffold, newname, transfer)

                if next_scaffold in corrections:
                    move_corrections(next_scaffold, newname, newstart+100, lastpart, corrections, log)
                del genome[next_scaffold]

                if new != newname:
                    if new in corrections:
                        move_corrections(new, newname, 1, 0, corrections, log)
                    del genome[new]
                    log.write("\tMerged {} and {} into {}\n".format(new, next_scaffold, newname))
                else:
                    log.write("\tMerged {} into {}\n".format(next_scaffold, newname))

                last_merge = newname
            else:
                last_merge = None
                if new in genome:
                    log.write("Keeping {}\n".format(new))
                else:
                    # Already merged
                    pass
    return newnumber+1


def make_new_scaffold(scaffold, start, end, newnumber, genome, transfer, log):
    newname = 'HE' + str(newnumber)
    log.write('\tMaking {} from {} {} and {}\n'.format(newname, scaffold, start, end))
    # FASTA
    length = end-start+1
    genome[newname] = genome[scaffold][start-1:end]
    genome[newname].id = genome[newname].name = genome[newname].description = newname

    # Transfer
    for tstart in sorted(transfer[scaffold]):
        tr = transfer[scaffold][tstart]
        if start > tr.newend or end < tr.newstart:
            continue
        partstart = max(start, tr.newstart)
        partend = min(end, tr.newend)
        offset = partstart - tr.newstart
        partlen = partend - partstart + 1
        newstart = partstart-start+1
        transfer[newname][newstart] = Transfer(tr.oldname, tr.oldstart + offset, partlen + offset, newname, newstart, partend-start+1, tr.strand, tr.parttype)
    newnumber += 1
    return newname, newnumber

def delete_scaffold(scaffold, genome, transfer, corrections, log):
    log.write("Deleting {}\n".format(scaffold))
    del genome[scaffold]
    del transfer[scaffold]
    del corrections[scaffold]

def correct_genome(newnumber, genome, scaffolds, transfer, corrections, log):
    
    total_removal = 0
    
    for scaffold in sorted(corrections):
        newstart = 1
        new_scaffolds = []
        write_last = True
        for start in sorted(corrections[scaffold]):
            cor = corrections[scaffold][start]
            log.write(repr(cor) + '\n')
            breakstart = breakend = None
            
            if cor.breaktype == 'B': # Split so this position is start of new scaffold
                new_scaffolds.append((newstart, int(cor.details)-1))
                newstart = int(cor.details)

            elif cor.breaktype == 'R' and cor.details == "All": # Delete whole scaffold
                length = len(genome[scaffold])
                log.write("Removed\t{}\t{}\t{}\t{}\n".format(scaffold, 1, length, length))
                total_removal += length
                write_last = False

            elif '-' in cor.details:
                breakstart, breakend = [int(p) for p in cor.details.split('-')]

            elif cor.breaktype == 'R': # Found AGP part(s); remove these parts
                parts = [int(p) for p in cor.details.split('+')]
                for start in sorted(scaffolds[cor.scaffold]):
                    agpline = scaffolds[cor.scaffold][start]
                    if agpline.part == parts[0]:
                        breakstart = agpline.start
                    if agpline.part == parts[-1]:
                        breakend = agpline.end
            else:
                print("Unknown breaktype!", cor)

            if breakstart and breakend:
                new_scaffolds.append((newstart, breakstart-1))
                if cor.breaktype == 'K':
                    new_scaffolds.append((breakstart, breakend))
                newstart = breakend+1

        if write_last:
            new_scaffolds.append((newstart, len(genome[scaffold])))

        lastend = None
        for start, end in new_scaffolds:
            newname, newnumber = make_new_scaffold(scaffold, start, end, newnumber, genome, transfer, log)
            if lastend and start-lastend > 1:
                total_removal += start-lastend-1
                log.write("Removed\t{}\t{}\t{}\t{}\n".format(scaffold, lastend+1, start-1, start-lastend-1))
                
            lastend = end

        delete_scaffold(scaffold, genome, transfer, corrections, log)

    log.write("In total, removed {} bp\n".format(total_removal))

def output_genome(genome, scaffolds, transfer, output):
    try:
        with open(output + ".fasta", 'w') as fasta:
            for scaffold in sorted(genome):
                SeqIO.write(genome[scaffold], fasta, "fasta")

        with open (output + ".tsv", 'w') as tsv:
            for scaffold in sorted(transfer):
                for start in sorted(transfer[scaffold], key = lambda x: transfer[scaffold][x].newstart):
                    tsv.write(repr(transfer[scaffold][start]) + '\n')
    except IOError:
        print("Can't write output files")
        sys.exit()
    
def get_args():
    parser = argparse.ArgumentParser(description='''Output TSV of new scaffolds from draft genome, correcting misassemblies
        -f fasta
        -c corrections
        -a agp
        -o output
        -r real_breakages
        ''')

    parser.add_argument('-f', '--fasta', type=str, required=True)
    parser.add_argument('-c', '--corrections', type=str, required=True)
    parser.add_argument('-a', '--agp', type=str, required=True)
    parser.add_argument('-o', '--output', type=str, required=True)
    parser.add_argument('-r', '--real_breakages', type=str, required=True)

    return parser.parse_args()

if __name__ == '__main__':
    
    args = get_args()

    log = open(args.output + '.log', 'w')

    genome, transfer = load_genome(args.fasta)
    log.write("Genome has {} scaffolds, {} bp long\n".format(len(genome), sum([len(genome[s]) for s in genome])))

    corrections = load_corrections(args.corrections, genome)
    
    scaffolds, broken_scaffolds = load_broken_scaffolds(args.agp, args.real_breakages)

    newnumber = merge_broken(broken_scaffolds, genome, scaffolds, corrections, transfer, log)
    
    log.write("After merge, genome has {} scaffolds, {} bp long\n".format(len(genome), sum([len(genome[s]) for s in genome])))
    
    correct_genome(newnumber, genome, scaffolds, transfer, corrections, log)

    log.write("After correction, genome has {} scaffolds, {} bp long\n".format(len(genome), sum([len(genome[s]) for s in genome])))

    output_genome(genome, scaffolds, transfer, args.output)