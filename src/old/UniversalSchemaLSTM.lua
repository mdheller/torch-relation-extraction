--
-- User: pat
-- Date: 8/26/15
--

package.path = package.path .. ";src/?.lua"

require 'CmdArgs'

local params = CmdArgs:parse(arg)
torch.manualSeed(0)

print('Using ' .. (params.gpuid >= 0 and 'GPU' or 'CPU'))
if params.gpuid >= 0 then require 'cunn'; cutorch.manualSeed(0); cutorch.setDevice(params.gpuid + 1) else require 'nn' end
require 'rnn'


local function lstm_encoder(params)
    local train_data = torch.load(params.train)

    local encoder
    local rel_table
    if params.loadEncoder ~= '' then
        local loaded_model = torch.load(params.loadEncoder)
        encoder = loaded_model.encoder
        rel_table = loaded_model.rel_table:clone()
    else
        local inputSize = params.wordDim > 0 and params.wordDim or (params.relDim > 0 and params.relDim or params.embeddingDim)
        local outputSize = params.relDim > 0 and params.relDim or params.embeddingDim

        local rel_size = train_data.num_tokens
        -- never update word embeddings, these should be preloaded
        if params.noWordUpdate then
            require 'nn-modules/NoUpdateLookupTable'
            rel_table = nn.NoUpdateLookupTable(rel_size, inputSize):add(nn.TemporalConvolution(inputSize, inputSize, 1))
        else
            rel_table = nn.LookupTable(rel_size, inputSize)
        end

        -- initialize in range [-.1, .1]
        rel_table.weight = torch.rand(rel_size, inputSize):add(-.5):mul(0.1)
        if params.loadRelEmbeddings ~= '' then
            rel_table.weight = (torch.load(params.loadRelEmbeddings))
        end

        encoder = nn.Sequential()
        -- word dropout
        if params.wordDropout > 0 then
            require 'nn-modules/WordDropout'
            encoder:add(nn.WordDropout(params.wordDropout, 1))
        end

        encoder:add(rel_table)
        if params.dropout > 0.0 then encoder:add(nn.Dropout(params.dropout)) end
        encoder:add(nn.SplitTable(2)) -- tensor to table of tensors

        -- recurrent layer
        local lstm = nn.Sequential()
        for i = 1, params.layers do
            local layer_output_size = (i < params.layers or not string.find(params.bi, 'concat')) and outputSize or outputSize / 2
            local layer_input_size = i == 1 and inputSize or outputSize
            local recurrent_cell =
            -- regular rnn
            params.rnnCell and nn.Recurrent(layer_output_size, nn.Linear(layer_input_size, layer_output_size),
                    nn.Linear(layer_output_size, layer_output_size), nn.Sigmoid(), 9999)
            -- lstm
            or nn.FastLSTM(layer_input_size, layer_output_size)
            if params.bi == "add" then
                lstm:add(nn.BiSequencer(recurrent_cell, recurrent_cell:clone(), nn.CAddTable()))
            elseif params.bi == "linear" then
                lstm:add(nn.Sequential():add(nn.BiSequencer(recurrent_cell, recurrent_cell:clone())):add
                (nn.Sequencer(nn.Linear(layer_output_size*2, layer_output_size))))
    --        elseif params.bi == "concat" then
    --            lstm:add(nn.BiSequencer(recurrent_cell, recurrent_cell:clone()))
    --        elseif params.bi == "no-reverse-concat" then
    --            require 'nn-modules/NoUnReverseBiSequencer'
    --            lstm:add(nn.NoUnReverseBiSequencer(recurrent_cell, recurrent_cell:clone()))
            else
                lstm:add(nn.Sequencer(recurrent_cell))
            end
            if params.layerDropout > 0.0 then lstm:add(nn.Sequencer(nn.Dropout(params.layerDropout))) end
        end
        encoder:add(lstm)

        if params.attention then
            require 'nn-modules/ViewTable'
            require 'nn-modules/ReplicateAs'
            require 'nn-modules/SelectLast'
            require 'nn-modules/VariableLengthJoinTable'
            require 'nn-modules/VariableLengthConcatTable'

            local mixture_dim = outputSize
            local M = nn.Sequential()
            local term_1 = nn.Sequential()
            term_1:add(nn.TemporalConvolution(outputSize, mixture_dim, 1))

            local term_2_linear = nn.Sequential()
            term_2_linear:add(nn.SelectLast(2))
            term_2_linear:add(nn.Linear(mixture_dim, mixture_dim))

            local term_2_concat = nn.VariableLengthConcatTable()
            term_2_concat:add(term_2_linear)
            term_2_concat:add(nn.Identity())

            local term_2 = nn.Sequential()
            term_2:add(term_2_concat)
            term_2:add(nn.ReplicateAs(2, 2))

            local M_concat = nn.VariableLengthConcatTable():add(term_1):add(term_2)
            M:add(M_concat):add(nn.CAddTable())

            local Y = nn.Identity()
            local alpha = nn.Sequential():add(M):add(nn.TemporalConvolution(mixture_dim,1,1)):add(nn.Select(3,1)):add(nn.SoftMax()):add(nn.Replicate(1,2))
            local concat_table = nn.ConcatTable():add(alpha):add(Y)

            local attention = nn.Sequential()
            attention:add(concat_table)
            attention:add(nn.MM())
            --    attention:add(nn.MixtureTable())

            encoder:add(nn.ViewTable(-1, 1, outputSize))
            encoder:add(nn.VariableLengthJoinTable(2))
            encoder:add(attention)
            encoder:add(nn.View(-1, mixture_dim))

        elseif params.poolLayer ~= '' then
            assert(params.poolLayer == 'Mean' or params.poolLayer == 'Max',
                'valid options for poolLayer are Mean and Max')
            require 'nn-modules/ViewTable'
            encoder:add(nn.ViewTable(-1, 1, outputSize))
            encoder:add(nn.JoinTable(2))
            encoder:add(nn[params.poolLayer](2))
        else
            encoder:add(nn.SelectTable(-1))
        end
    end


    if params.poolRelations then
        require 'nn-modules/EncoderPool'
        encoder = nn.EncoderPool(encoder:clone(), nn.Max(2))
    end

    return encoder, rel_table
end

local encoder, rel_table = lstm_encoder(params)

local model
if params.entityModel then
    require 'UniversalSchemaEntityEncoder'
    model = UniversalSchemaEntityEncoder(params, rel_table, encoder)
else
    require 'UniversalSchemaEncoder'
    model = UniversalSchemaEncoder(params, rel_table, encoder)
end

print(model.net)
model:train()
if params.saveModel ~= '' then  model:save_model(params.numEpochs) end

--batches = model:gen_training_batches(model.train_data)
--x = batches[2000].data
--batch = torch.ones(10,3)
----print ({batch})
--e = encoder:get(3)(encoder:get(2)(encoder:get(1)(batch)))
--ec = term_2_concat(e)
----print(e)
--
--pred = model.net:forward(x)
--theta = pred[1] - pred[2]
--prob = theta:clone():fill(1):cdiv(torch.exp(-theta):add(1))
--err = torch.log(prob):mean()
--step = (prob:clone():fill(1) - prob)
--df_do = { -step, step }
--model.net:backward(x, df_do)

--print({encoder:forward(batch)})


